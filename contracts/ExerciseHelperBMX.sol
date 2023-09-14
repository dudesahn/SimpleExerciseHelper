// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.17;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

interface IoToken is IERC20 {
    function exercise(
        uint256 _amount,
        uint256 _maxPaymentAmount,
        address _recipient
    ) external returns (uint256);

    function getDiscountedPrice(
        uint256 _amount
    ) external view returns (uint256);

    function discount() external view returns (uint256);
}

interface IBalancer {
    function flashLoan(
        address recipient,
        address[] memory tokens,
        uint256[] memory amounts,
        bytes memory userData
    ) external;
}

interface IRouter {
    struct route {
        address from;
        address to;
        bool stable;
    }

    function quoteMintAmountBLT(
        address _underlyingToken,
        uint256 _bltAmountNeeded
    ) external view returns (uint256);

    function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        route[] calldata routes,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);

    function getAmountsOut(
        uint amountIn,
        route[] memory routes
    ) external view returns (uint[] memory amounts);
}

/**
 * @title Exercise Helper BMX
 * @notice This contract easily converts oBMX to WETH using flash loans.
 */

contract ExerciseHelperBMX is Ownable2Step {
    /// @notice Option token address
    IoToken internal constant oBMX =
        IoToken(0x3Ff7AB26F2dfD482C40bDaDfC0e88D01BFf79713);

    /// @notice WETH, payment token
    IERC20 internal constant weth =
        IERC20(0x4200000000000000000000000000000000000006);

    /// @notice BMX, sell this for WETH
    IERC20 internal constant bmx =
        IERC20(0x548f93779fBC992010C07467cBaf329DD5F059B7);

    /// @notice Wrapped BLT, our auto-compounding LP vault token
    IERC20 internal constant wBLT =
        IERC20(0x4E74D4Db6c0726ccded4656d0BCE448876BB4C7A);

    /// @notice Flashloan from Balancer vault
    IBalancer internal constant balancerVault =
        IBalancer(0xBA12222222228d8Ba445958a75a0704d566BF2C8);

    /// @notice BMX router for swaps
    IRouter internal constant router =
        IRouter(0x40CfeC24170f6e87D645d5884a7c854Cb208314F);

    /// @notice Check whether we are in the middle of a flashloan (used for callback)
    bool public flashEntered;

    /// @notice Where we send our 0.25% fee
    address public feeAddress = 0x58761D6C6bF6c4bab96CaE125a2e5c8B1859b48a;

    uint256 public fee = 25;

    uint256 internal constant MAX_BPS = 10_000;
    uint256 internal constant DISCOUNT_DENOMINATOR = 100;

    /// @notice Route for selling BMX -> WETH
    IRouter.route[] internal bmxToWeth;

    /// @notice Route for selling wBLT -> WETH
    IRouter.route[] internal wBltToWeth;

    /// @notice Route for selling WETH -> wBLT
    IRouter.route[] internal wethToWblt;

    constructor(
        IRouter.route[] memory _wBltToWeth,
        IRouter.route[] memory _bmxToWeth,
        IRouter.route[] memory _wethToWblt
    ) {
        // create our swap routes
        for (uint i; i < _wBltToWeth.length; ++i) {
            wBltToWeth.push(_wBltToWeth[i]);
        }

        for (uint i; i < _bmxToWeth.length; ++i) {
            bmxToWeth.push(_bmxToWeth[i]);
        }

        for (uint i; i < _wethToWblt.length; ++i) {
            wethToWblt.push(_wethToWblt[i]);
        }

        // do necessary approvals
        weth.approve(address(oBMX), type(uint256).max);
        wBLT.approve(address(oBMX), type(uint256).max);
        bmx.approve(address(router), type(uint256).max);
        weth.approve(address(router), type(uint256).max);
        wBLT.approve(address(router), type(uint256).max);
    }

    /**
     * @notice Check if spot swap and exercising fall are similar enough for our liking.
     * @param _optionTokenAmount The amount of oBMX to exercise to WETH.
     * @param _profitSlippageAllowed Considers effect of TWAP vs spot pricing of options on profit outcomes.
     * @return wethNeeded How much WETH is needed for given amount of oBMX.
     * @return withinSlippageTolerance Whether expected vs real profit fall within our slippage tolerance.
     * @return realProfit Simulated profit in WETH after repaying flash loan.
     * @return expectedProfit Calculated ideal profit based on redemption discount plus allowed slippage.
     * @return profitSlippage Expected profit slippage with given oToken amount, 18 decimals. Zero
     *  means extra profit (positive slippage).
     */
    function quoteExerciseProfit(
        uint256 _optionTokenAmount,
        uint256 _profitSlippageAllowed
    )
        public
        view
        returns (
            uint256 wethNeeded,
            bool withinSlippageTolerance,
            uint256 realProfit,
            uint256 expectedProfit,
            uint256 profitSlippage
        )
    {
        if (_optionTokenAmount == 0) {
            revert("Can't exercise zero");
        }
        if (_profitSlippageAllowed > MAX_BPS) {
            revert("Slippage must be less than 10,000");
        }

        // calculate how much WETH we need for our oBMX amount
        // we need this many wBLT for a given amount of oBMX
        uint256 wBLTNeeded = oBMX.getDiscountedPrice(_optionTokenAmount);
        // we need this much WETH to mint that much wBLT
        wethNeeded = router.quoteMintAmountBLT(address(weth), wBLTNeeded);

        // compare our weth needed to simulated swap
        uint256[] memory amounts = router.getAmountsOut(
            _optionTokenAmount,
            bmxToWeth
        );
        uint256 wethReceived = amounts[2];

        // compare make sure we don't spend more than we have
        if (wethNeeded > wethReceived) {
            revert("Cost exceeds profit");
        } else {
            realProfit = wethReceived - wethNeeded;
        }

        uint256 discount = oBMX.discount();
        expectedProfit =
            (wethNeeded * (DISCOUNT_DENOMINATOR - discount)) /
            discount;

        // if profitSlippage returns zero, we have positive slippage (extra profit)
        if (expectedProfit > realProfit) {
            profitSlippage = 1e18 - ((realProfit * 1e18) / expectedProfit);
        }

        // allow for our expected slippage as well
        expectedProfit =
            (expectedProfit * (MAX_BPS - _profitSlippageAllowed)) /
            MAX_BPS;

        // check if real profit is greater than expected when accounting for allowed slippage
        if (realProfit > expectedProfit) {
            withinSlippageTolerance = true;
        }
    }

    /**
     * @notice Exercise our oBMX for WETH.
     * @param _amount The amount of oBMX to exercise to WETH.
     * @param _profitSlippageAllowed Considers effect of TWAP vs spot pricing of options on profit outcomes.
     * @param _swapSlippageAllowed Slippage (really price impact) we allow while exercising.
     */
    function exercise(
        uint256 _amount,
        uint256 _profitSlippageAllowed,
        uint256 _swapSlippageAllowed
    ) external {
        // check that slippage tolerance for profit is okay
        (
            uint256 wethNeeded,
            bool withinSlippageTolerance,
            ,
            ,

        ) = quoteExerciseProfit(_amount, _profitSlippageAllowed);

        // revert if too much slippage
        if (!withinSlippageTolerance) {
            revert("Profit slippage higher than allowed");
        }

        // transfer option token to this contract
        _safeTransferFrom(address(oBMX), msg.sender, address(this), _amount);

        // get our flash loan started
        _borrowPaymentToken(wethNeeded, _swapSlippageAllowed);

        // send remaining profit back to user
        _safeTransfer(address(weth), msg.sender, weth.balanceOf(address(this)));

        // swap any leftover wBLT to WETH, unless dust, then just send back as wBLT
        uint256 remainingBalance = wBLT.balanceOf(address(this));
        if (remainingBalance > 1e17) {
            router.swapExactTokensForTokens(
                remainingBalance,
                0,
                wBltToWeth,
                msg.sender,
                block.timestamp
            );
        } else {
            _safeTransfer(address(wBLT), msg.sender, remainingBalance);
        }
    }

    /**
     * @notice Flash loan our WETH from Balancer.
     * @param _wethNeeded The amount of WETH needed.
     * @param _slippageAllowed Slippage (really price impact) we allow while exercising.
     */
    function _borrowPaymentToken(
        uint256 _wethNeeded,
        uint256 _slippageAllowed
    ) internal {
        // change our state
        flashEntered = true;

        address _weth = address(weth);

        // create our input args
        address[] memory tokens = new address[](1);
        tokens[0] = _weth;

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = _wethNeeded;

        bytes memory userData = abi.encode(_wethNeeded, _slippageAllowed);

        // call the flash loan
        balancerVault.flashLoan(address(this), tokens, amounts, userData);
    }

    /**
     * @notice Fallback function used during flash loans.
     * @dev May only be called by balancer vault as part of
     *  flash loan callback.
     * @param _tokens The tokens we are swapping (in our case, only WETH).
     * @param _amounts The amounts of said tokens.
     * @param _feeAmounts The fee amounts for said tokens.
     * @param _userData Payment token amount passed from our flash loan.
     */
    function receiveFlashLoan(
        address[] memory _tokens,
        uint256[] memory _amounts,
        uint256[] memory _feeAmounts,
        bytes memory _userData
    ) external {
        // only balancer vault may call this, during a flash loan
        if (msg.sender != address(balancerVault)) {
            revert("Only balancer vault can call");
        }
        if (!flashEntered) {
            revert("Flashloan not in progress");
        }

        // pull our option info from the userData
        (uint256 wethToExercise, uint256 slippageAllowed) = abi.decode(
            _userData,
            (uint256, uint256)
        );

        // exercise our option with our new WETH, swap all BMX to WETH
        uint256 optionTokenBalance = oBMX.balanceOf(address(this));
        _exerciseAndSwap(optionTokenBalance, wethToExercise, slippageAllowed);

        // check our output and take fees
        uint256 wethAmount = weth.balanceOf(address(this));
        _takeFees(wethAmount);

        // repay our flash loan
        uint256 payback = _amounts[0] + _feeAmounts[0];
        _safeTransfer(address(weth), address(balancerVault), payback);
        flashEntered = false;
    }

    /**
     * @notice Exercise our oBMX, then swap BMX to WETH.
     * @param _optionTokenAmount Amount of oBMX to exercise.
     * @param _wethAmount Amount of WETH needed to pay for exercising. Must
     *  first be converted to wBLT.
     * @param _slippageAllowed Slippage (really price impact) we allow while exercising.
     */
    function _exerciseAndSwap(
        uint256 _optionTokenAmount,
        uint256 _wethAmount,
        uint256 _slippageAllowed
    ) internal {
        // deposit our weth to wBLT
        uint256[] memory amountsWeth = router.swapExactTokensForTokens(
            _wethAmount,
            0,
            wethToWblt,
            address(this),
            block.timestamp
        );

        oBMX.exercise(_optionTokenAmount, amountsWeth[1], address(this));
        uint256 bmxReceived = bmx.balanceOf(address(this));

        // use this to minimize issues with slippage
        uint256[] memory amounts = router.getAmountsOut(1e18, bmxToWeth);
        uint256 wethPerBmx = amounts[2];

        uint256 minAmountOut = (bmxReceived *
            wethPerBmx *
            (MAX_BPS - _slippageAllowed)) / (1e18 * MAX_BPS);

        // use our router to swap from BMX to WETH
        router.swapExactTokensForTokens(
            bmxReceived,
            minAmountOut,
            bmxToWeth,
            address(this),
            block.timestamp
        );
    }

    /**
     * @notice Apply fees to our after-swap total.
     * @dev Default is 0.25% but this may be updated later.
     * @param _amount Amount to apply our fee to.
     */
    function _takeFees(uint256 _amount) internal {
        uint256 toSend = (_amount * fee) / MAX_BPS;
        _safeTransfer(address(weth), feeAddress, toSend);
    }

    /**
     * @notice Sweep out tokens accidentally sent here.
     * @dev May only be called by owner.
     * @param _tokenAddress Address of token to sweep.
     * @param _tokenAmount Amount of tokens to sweep.
     */
    function recoverERC20(
        address _tokenAddress,
        uint256 _tokenAmount
    ) external onlyOwner {
        _safeTransfer(_tokenAddress, owner(), _tokenAmount);
    }

    /**
     * @notice
     *  Update fee for oBMX -> WETH conversion.
     * @param _recipient Fee recipient address.
     * @param _newFee New fee, out of 10,000.
     */
    function setFee(address _recipient, uint256 _newFee) external onlyOwner {
        if (_newFee > DISCOUNT_DENOMINATOR) {
            revert("Fee max is 1%");
        }
        fee = _newFee;
        feeAddress = _recipient;
    }

    /* ========== HELPER FUNCTIONS ========== */

    function _safeTransfer(address token, address to, uint256 value) internal {
        require(token.code.length > 0);
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(IERC20.transfer.selector, to, value)
        );
        require(success && (data.length == 0 || abi.decode(data, (bool))));
    }

    function _safeTransferFrom(
        address token,
        address from,
        address to,
        uint256 value
    ) internal {
        require(token.code.length > 0);
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(
                IERC20.transferFrom.selector,
                from,
                to,
                value
            )
        );
        require(success && (data.length == 0 || abi.decode(data, (bool))));
    }
}
