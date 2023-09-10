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
    IoToken public constant oBMX =
        IoToken(0x3Ff7AB26F2dfD482C40bDaDfC0e88D01BFf79713);

    /// @notice WETH, payment token
    IERC20 public constant weth =
        IERC20(0x4200000000000000000000000000000000000006);

    /// @notice BMX, sell this for WETH
    IERC20 public constant bmx =
        IERC20(0x548f93779fBC992010C07467cBaf329DD5F059B7);

    IERC20 public constant wBLT =
        IERC20(0x4E74D4Db6c0726ccded4656d0BCE448876BB4C7A);

    /// @notice Flashloan from Balancer vault
    IBalancer public constant balancerVault =
        IBalancer(0xBA12222222228d8Ba445958a75a0704d566BF2C8);

    /// @notice BMX router for swaps
    IRouter constant router =
        IRouter(0x82E98c956BAe12961e89d5107df78D3298aa151a);

    /// @notice Check whether we are in the middle of a flashloan (used for callback)
    bool public flashEntered;

    /// @notice Where we send our 0.25% fee
    address public constant feeAddress =
        0x58761D6C6bF6c4bab96CaE125a2e5c8B1859b48a;

    /// @notice Route for selling BMX -> WETH
    IRouter.route[] public bmxToWeth;

    /// @notice Route for selling wBLT -> WETH
    IRouter.route[] public wBltoWeth;

    /// @notice Route for selling WETH -> wBLT
    IRouter.route[] public wethToWblt;

    constructor(
        IRouter.route[] memory _wBltoWeth,
        IRouter.route[] memory _bmxToWeth,
        IRouter.route[] memory _wethToWblt
    ) {
        // create our swap routes
        for (uint i; i < _wBltoWeth.length; ++i) {
            wBltoWeth.push(_wBltoWeth[i]);
        }

        for (uint i; i < _bmxToWeth.length; ++i) {
            bmxToWeth.push(_bmxToWeth[i]);
        }

        for (uint i; i < _wethToWblt.length; ++i) {
            wethToWblt.push(_wethToWblt[i]);
        }

        // do necessary approvals
        weth.approve(address(oBMX), type(uint256).max);
        bmx.approve(address(router), type(uint256).max);
        weth.approve(address(router), type(uint256).max);
    }

    /**
     * @notice Exercise our oBMX for WETH.
     * @param _amount The amount of oBMX to exercise to WETH.
     */
    function exercise(uint256 _amount) external {
        if (_amount == 0) {
            revert("Can't exercise zero");
        }

        // transfer option token to this contract
        _safeTransferFrom(address(oBMX), msg.sender, address(this), _amount);

        // figure out how much wBLT we need for our oBMX amount
        uint256 paymentTokenNeeded = oBMX.getDiscountedPrice(_amount);

        // get our flash loan started
        _borrowPaymentToken(paymentTokenNeeded);

        // send remaining profit back to user
        _safeTransfer(address(weth), msg.sender, weth.balanceOf(address(this)));
    }

    /**
     * @notice Flash loan our WETH from Balancer.
     * @param _amountNeeded The amount of WETH needed.
     */
    function _borrowPaymentToken(uint256 _amountNeeded) internal {
        // change our state
        flashEntered = true;
        
        address _weth = address(weth);

        // need top convert this amount of wBLT to WETH
        _amountNeeded = router.quoteMintAmountBLT(_weth, _amountNeeded);

        // create our input args
        address[] memory tokens = new address[](1);
        tokens[0] = _weth;

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = _amountNeeded;

        bytes memory userData = abi.encode(_amountNeeded);

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
        uint256 paymentTokenNeeded = abi.decode(_userData, (uint256));

        // exercise our option with our new WETH, swap all BMX to WETH
        uint256 optionTokenBalance = oBMX.balanceOf(address(this));
        _exerciseAndSwap(optionTokenBalance, paymentTokenNeeded);

        uint256 payback = _amounts[0] + _feeAmounts[0];
        _safeTransfer(address(weth), address(balancerVault), payback);

        // check our profit and take fees
        uint256 profit = weth.balanceOf(address(this));
        _takeFees(profit);
        flashEntered = false;
    }

    /**
     * @notice Exercise our oBMX, then swap BMX to WETH.
     * @param _optionTokenAmount Amount of oBMX to exercise.
     * @param _paymentTokenAmount Amount of WETH needed to pay for exercising.
     */
    function _exerciseAndSwap(
        uint256 _optionTokenAmount,
        uint256 _paymentTokenAmount
    ) internal {
        // deposit our weth to wBLT
        router.swapExactTokensForTokens(
            _paymentAmount,
            0,
            wethToWblt,
            address(this),
            block.timestamp
        );

        oBMX.exercise(
            _oBMXBalance,
            wBLT.balanceOf(address(this)),
            address(this)
        );
        uint256 bmxReceived = bmx.balanceOf(address(this));

        // use our router to swap from BMX to WETH
        router.swapExactTokensForTokens(
            bmxReceived,
            0,
            bmxToWeth,
            address(this),
            block.timestamp
        );
    }

    /**
     * @notice Apply fees to our profit amount.
     * @param _profitAmount Amount to apply 0.25% fee to.
     */
    function _takeFees(uint256 _profitAmount) internal {
        uint256 toSend = (_profitAmount * 25) / 10_000;
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
