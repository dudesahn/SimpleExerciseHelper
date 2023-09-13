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

    function getAmountOut(
        uint amountIn,
        address tokenIn,
        address tokenOut,
        bool stable
    ) external view returns (uint amount);

    function getAmountsOut(
        uint amountIn,
        route[] memory routes
    ) external view returns (uint[] memory amounts);

    function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        route[] calldata routes,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);
}

/**
 * @title Exercise Helper BVM
 * @notice This contract easily converts oBVM to WETH using flash loans.
 */

contract ExerciseHelperBVM is Ownable2Step {
    /// @notice Option token address
    IoToken public constant oBVM =
        IoToken(0x762eb51D2e779EeEc9B239FFB0B2eC8262848f3E);

    /// @notice WETH, payment token
    IERC20 public constant weth =
        IERC20(0x4200000000000000000000000000000000000006);

    /// @notice BVM, sell this for WETH
    IERC20 public constant bvm =
        IERC20(0xd386a121991E51Eab5e3433Bf5B1cF4C8884b47a);

    /// @notice Flashloan from Balancer vault
    IBalancer public constant balancerVault =
        IBalancer(0xBA12222222228d8Ba445958a75a0704d566BF2C8);

    /// @notice BVM router for swaps
    IRouter constant router =
        IRouter(0xE11b93B61f6291d35c5a2beA0A9fF169080160cF);

    /// @notice Check whether we are in the middle of a flashloan (used for callback)
    bool public flashEntered;

    /// @notice Where we send our 0.25% fee
    address public constant feeAddress =
        0x58761D6C6bF6c4bab96CaE125a2e5c8B1859b48a;

    uint256 internal constant MAX_BPS = 10_000;
    uint256 internal constant DISCOUNT_DENOMINATOR = 100;

    /// @notice Route for selling BVM -> WETH
    IRouter.route[] public bvmToWeth;

    constructor(IRouter.route[] memory _bvmToWeth) {
        // create our swap route
        for (uint i; i < _bvmToWeth.length; ++i) {
            bvmToWeth.push(_bvmToWeth[i]);
        }

        // do necessary approvals
        bvm.approve(address(router), type(uint256).max);
        weth.approve(address(oBVM), type(uint256).max);
    }

    /**
     * @notice Check if spot swap and exercising fall are similar enough for our liking.
     * @param _optionTokenAmount The amount of oBVM to exercise to WETH.
     * @param _profitSlippageAllowed Considers effect of TWAP vs spot pricing of options on profit outcomes.
     * @return paymentTokenNeeded How much payment token is needed for given amount of oToken.
     * @return withinSlippageTolerance Whether expected vs real profit fall within our slippage tolerance.
     * @return realProfit Simulated profit in paymentToken after repaying flash loan.
     */
    function quoteExerciseProfit(
        uint256 _optionTokenAmount,
        uint256 _profitSlippageAllowed
    )
        public
        view
        returns (
            uint256 paymentTokenNeeded,
            bool withinSlippageTolerance,
            uint256 realProfit,
            uint256 expectedProfitDeleteBeforeProd
        )
    {
        if (_optionTokenAmount == 0) {
            revert("Can't exercise zero");
        }
        if (_profitSlippageAllowed > MAX_BPS) {
            revert("Slippage must be less than 10,000");
        }

        // figure out how much WETH we need for our oBVM amount
        paymentTokenNeeded = oBVM.getDiscountedPrice(_optionTokenAmount);

        // compare our token needed to spot price
        uint256 spotPaymentTokenReceived = router.getAmountOut(
            _optionTokenAmount,
            address(bvm),
            address(weth),
            false
        );

        // check our simulated and ideal profit
        realProfit = spotPaymentTokenReceived - paymentTokenNeeded;
        uint256 expectedProfit = (spotPaymentTokenReceived *
            (DISCOUNT_DENOMINATOR - oBVM.discount())) / DISCOUNT_DENOMINATOR;

        if (realProfit > expectedProfit) {
            // if TWAP is in our favor, then we automatically are within our tolerance (get more than we would expect)
            withinSlippageTolerance = true;
        } else {
            // otherwise, check if real profit is greater than expected when accounting for allowed slippage
            withinSlippageTolerance =
                realProfit >
                (expectedProfit * (MAX_BPS - _profitSlippageAllowed)) / MAX_BPS;
        }
        expectedProfitDeleteBeforeProd = expectedProfit;
    }

    /**
     * @notice Exercise our oBVM for WETH.
     * @param _amount The amount of oBVM to exercise to WETH.
     * @param _profitSlippageAllowed Considers effect of TWAP vs spot pricing of options on profit outcomes.
     * @param _swapSlippageAllowed Slippage (really price impact) we allow while exercising.
     */
    function exercise(
        uint256 _amount,
        uint256 _profitSlippageAllowed,
        uint256 _swapSlippageAllowed
    ) external {
        // transfer option token to this contract
        _safeTransferFrom(address(oBVM), msg.sender, address(this), _amount);

        // check that slippage tolerance for profit is okay
        (
            uint256 paymentTokenNeeded,
            bool withinSlippageTolerance,
            ,

        ) = quoteExerciseProfit(_amount, _profitSlippageAllowed);

        if (!withinSlippageTolerance) {
            revert("Profit not within slippage tolerance, check TWAP");
        }

        // get our flash loan started
        _borrowPaymentToken(paymentTokenNeeded, _swapSlippageAllowed);

        // send remaining profit back to user
        _safeTransfer(address(weth), msg.sender, weth.balanceOf(address(this)));
    }

    /**
     * @notice Flash loan our WETH from Balancer.
     * @param _amountNeeded The amount of WETH needed.
     * @param _slippageAllowed Slippage (really price impact) we allow while exercising.
     */
    function _borrowPaymentToken(
        uint256 _amountNeeded,
        uint256 _slippageAllowed
    ) internal {
        // change our state
        flashEntered = true;

        // create our input args
        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = _amountNeeded;

        bytes memory userData = abi.encode(_amountNeeded, _slippageAllowed);

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
        (uint256 paymentTokenNeeded, uint256 slippageAllowed) = abi.decode(
            _userData,
            (uint256, uint256)
        );

        // exercise our option with our new WETH, swap all BVM to WETH
        uint256 optionTokenBalance = oBVM.balanceOf(address(this));
        _exerciseAndSwap(
            optionTokenBalance,
            paymentTokenNeeded,
            slippageAllowed
        );

        uint256 payback = _amounts[0] + _feeAmounts[0];
        _safeTransfer(address(weth), address(balancerVault), payback);

        // check our profit and take fees
        uint256 profit = weth.balanceOf(address(this));
        _takeFees(profit);
        flashEntered = false;
    }

    /**
     * @notice Exercise our oBVM, then swap BVM to WETH.
     * @param _optionTokenAmount Amount of oBVM to exercise.
     * @param _paymentTokenAmount Amount of WETH needed to pay for exercising.
     * @param _slippageAllowed Slippage (really price impact) we allow while exercising.
     */
    function _exerciseAndSwap(
        uint256 _optionTokenAmount,
        uint256 _paymentTokenAmount,
        uint256 _slippageAllowed
    ) internal {
        oBVM.exercise(_optionTokenAmount, _paymentTokenAmount, address(this));
        uint256 bvmReceived = bvm.balanceOf(address(this));

        // use this to minimize issues with slippage (swapping with too much size)
        uint256 wethPerBvm = router.getAmountOut(
            1e18,
            address(bvm),
            address(weth),
            false
        );
        uint256 minAmountOut = (bvmReceived *
            wethPerBvm *
            (MAX_BPS - _slippageAllowed)) / (1e18 * MAX_BPS);

        // use our router to swap from BVM to WETH
        router.swapExactTokensForTokens(
            bvmReceived,
            minAmountOut,
            bvmToWeth,
            address(this),
            block.timestamp
        );
    }

    /**
     * @notice Apply fees to our profit amount.
     * @param _profitAmount Amount to apply 0.25% fee to.
     */
    function _takeFees(uint256 _profitAmount) internal {
        uint256 toSend = (_profitAmount * 25) / MAX_BPS;
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
