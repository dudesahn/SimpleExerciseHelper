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

    function underlyingToken() external view returns (address);
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

    function getReserves(
        address tokenA,
        address tokenB,
        bool stable
    ) external view returns (uint reserve0, uint reserve1);

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

    function swapExactTokensForTokensSimple(
        uint amountIn,
        uint amountOutMin,
        address tokenFrom,
        address tokenTo,
        bool stable,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);
}

/**
 * @title Simple Exercise Helper
 * @notice This contract easily converts oTokens paired with WETH
 *  such as oBVM to WETH using flash loans.
 */

contract SimpleExerciseHelper is Ownable2Step {
    /// @notice WETH, payment token
    IERC20 internal constant weth =
        IERC20(0x4200000000000000000000000000000000000006);

    /// @notice Flashloan from Balancer vault
    IBalancer internal constant balancerVault =
        IBalancer(0xBA12222222228d8Ba445958a75a0704d566BF2C8);

    /// @notice BVM router for swaps
    IRouter internal constant router =
        IRouter(0x68dc9978d159300767e541e0DDde1E1B2Ec79680);

    /// @notice Check whether we are in the middle of a flashloan (used for callback)
    bool public flashEntered;

    /// @notice Where we send our 0.25% fee
    address public feeAddress = 0x58761D6C6bF6c4bab96CaE125a2e5c8B1859b48a;

    uint256 public fee = 25;

    uint256 internal constant MAX_BPS = 10_000;
    uint256 internal constant DISCOUNT_DENOMINATOR = 100;

    /**
     * @notice Check if spot swap and exercising fall are similar enough for our liking.
     * @param _oToken The option token we are exercising.
     * @param _optionTokenAmount The amount of oToken to exercise to WETH.
     * @param _profitSlippageAllowed Considers effect of TWAP vs spot pricing of options on profit outcomes.
     * @return wethNeeded How much WETH is needed for given amount of oToken.
     * @return withinSlippageTolerance Whether expected vs real profit fall within our slippage tolerance.
     * @return realProfit Simulated profit in WETH after repaying flash loan.
     * @return expectedProfit Calculated ideal profit based on redemption discount plus allowed slippage.
     * @return profitSlippage Expected profit slippage with given oToken amount, 18 decimals. Zero
     *  means extra profit (positive slippage).
     */
    function quoteExerciseProfit(
        address _oToken,
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

        // figure out how much WETH we need for our oToken amount
        wethNeeded = IoToken(_oToken).getDiscountedPrice(_optionTokenAmount);

        // compare our token needed to spot price
        uint256 wethReceived = router.getAmountOut(
            _optionTokenAmount,
            IoToken(_oToken).underlyingToken(),
            address(weth),
            false
        );
        uint256 estimatedFee = (wethReceived * fee) / MAX_BPS;

        // compare make sure we don't spend more than we have
        if (wethNeeded > wethReceived - estimatedFee) {
            revert("Cost exceeds profit");
        } else {
            realProfit = wethReceived - wethNeeded - estimatedFee;
        }

        // calculate our ideal profit using the discount
        uint256 discount = IoToken(_oToken).discount();
        expectedProfit =
            ((wethNeeded * (DISCOUNT_DENOMINATOR - discount)) / discount) -
            estimatedFee;

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
     * @notice Check if spot swap and exercising are similar enough for our liking.
     * @param _oToken The option token we are exercising.
     * @param _optionTokenAmount The amount of oToken to exercise to underlying.
     * @param _profitSlippageAllowed Considers effect of TWAP vs spot pricing of options on profit outcomes.
     * @return wethNeeded How much WETH is needed for given amount of oToken.
     * @return withinSlippageTolerance Whether expected vs real profit fall within our slippage tolerance.
     * @return realProfit Simulated profit in underlying after repaying flash loan.
     * @return expectedProfit Calculated ideal profit based on redemption discount plus allowed slippage.
     * @return profitSlippage Expected profit slippage with given oToken amount, 18 decimals. Zero
     *  means extra profit (positive slippage).
     */
    function quoteExerciseToUnderlying(
        address _oToken,
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

        // figure out how much WETH we need for our oToken amount
        wethNeeded = IoToken(_oToken).getDiscountedPrice(_optionTokenAmount);

        // simulate swapping all to WETH to better estimate total WETH needed
        uint256 minAmount = router.getAmountOut(
            _optionTokenAmount,
            IoToken(_oToken).underlyingToken(),
            address(weth),
            false
        );
        minAmount = wethNeeded + (minAmount * fee) / MAX_BPS;

        // calculate how much underlying we need to get at least this much WETH
        address[] memory underlyingToWeth = new address[](2);
        underlyingToWeth[0] = IoToken(_oToken).underlyingToken();
        underlyingToWeth[1] = address(weth);
        uint256[] memory amounts = getAmountsIn(minAmount, underlyingToWeth);
        minAmount = amounts[0];

        // calculate our real and expected profit
        realProfit = _optionTokenAmount - minAmount;
        expectedProfit =
            (((_optionTokenAmount *
                (DISCOUNT_DENOMINATOR - IoToken(_oToken).discount())) /
                DISCOUNT_DENOMINATOR) * (MAX_BPS - fee)) /
            MAX_BPS;

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
     * @notice Exercise our oToken for WETH.
     * @param _oToken The option token we are exercising.
     * @param _amount The amount of oToken to exercise to WETH.
     * @param _receiveUnderlying Whether the user wants to receive WETH or underlying.
     * @param _profitSlippageAllowed Considers effect of TWAP vs spot pricing of options on profit outcomes.
     * @param _swapSlippageAllowed Slippage (really price impact) we allow while swapping underlying to WETH.
     */
    function exercise(
        address _oToken,
        uint256 _amount,
        bool _receiveUnderlying,
        uint256 _profitSlippageAllowed,
        uint256 _swapSlippageAllowed
    ) public {
        // first person does the approvals for everyone else, what a nice person!
        _checkAllowance(_oToken);

        // transfer option token to this contract
        _safeTransferFrom(_oToken, msg.sender, address(this), _amount);
        IERC20 oToken = IERC20(_oToken);

        // check that slippage tolerance for profit is okay
        (
            uint256 wethNeeded,
            bool withinSlippageTolerance,
            ,
            ,

        ) = quoteExerciseProfit(_oToken, _amount, _profitSlippageAllowed);

        if (!withinSlippageTolerance) {
            revert("Profit not within slippage tolerance, check TWAP");
        }

        // get our flash loan started
        _borrowPaymentToken(
            _oToken,
            oToken.balanceOf(address(this)),
            wethNeeded,
            _receiveUnderlying,
            _swapSlippageAllowed
        );

        // anything remaining in the helper is pure profit
        uint256 wethBalance = weth.balanceOf(address(this));

        if (_receiveUnderlying) {
            // pull out our underlying token
            IERC20 underlying = IERC20(IoToken(_oToken).underlyingToken());
            uint256 underlyingBalance = underlying.balanceOf(address(this));

            // swap any leftover WETH to underlying, unless dust, then just send back as WETH
            if (wethBalance > 1e14) {
                router.swapExactTokensForTokensSimple(
                    underlyingBalance,
                    0,
                    address(weth),
                    address(underlying),
                    false,
                    address(this),
                    block.timestamp
                );
                underlyingBalance = underlying.balanceOf(address(this));
            }

            // send underlying to user
            if (underlyingBalance > 0) {
                _safeTransfer(
                    address(underlying),
                    msg.sender,
                    underlyingBalance
                );
            }
        }

        if (wethBalance > 0) {
            _safeTransfer(address(weth), msg.sender, wethBalance);
        }
    }

    /**
     * @notice Flash loan our WETH from Balancer.
     * @param _oToken The option token we are exercising.
     * @param _oTokenToExercise The amount of oToken we are exercising.
     * @param _wethNeeded The amount of WETH needed.
     * @param _receiveUnderlying Whether the user wants to receive WETH or underlying.
     * @param _slippageAllowed Slippage (really price impact) we allow while exercising.
     */
    function _borrowPaymentToken(
        address _oToken,
        uint256 _oTokenToExercise,
        uint256 _wethNeeded,
        bool _receiveUnderlying,
        uint256 _slippageAllowed
    ) internal {
        // change our state
        flashEntered = true;

        // create our input args
        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = _wethNeeded;

        bytes memory userData = abi.encode(
            _oToken,
            _oTokenToExercise,
            _wethNeeded,
            _receiveUnderlying,
            _slippageAllowed
        );

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
        (
            address _oToken,
            uint256 _oTokenToExercise,
            uint256 _wethToExercise,
            bool _receiveUnderlying,
            uint256 _slippageAllowed
        ) = abi.decode(_userData, (address, uint256, uint256, bool, uint256));

        _exerciseAndSwap(
            _oToken,
            _oTokenToExercise,
            _wethToExercise,
            _receiveUnderlying,
            _slippageAllowed
        );

        // repay our flash loan
        uint256 payback = _amounts[0] + _feeAmounts[0];
        _safeTransfer(address(weth), address(balancerVault), payback);
        flashEntered = false;
    }

    /**
     * @notice Exercise our oToken, then swap underlying to WETH.
     * @param _oToken The option token we are exercising.
     * @param _optionTokenAmount Amount of oToken to exercise.
     * @param _wethAmount Amount of WETH needed to pay for exercising.
     * @param _receiveUnderlying Whether the user wants to receive WETH or underlying.
     * @param _slippageAllowed Slippage (really price impact) we allow while swapping underlying to WETH.
     */
    function _exerciseAndSwap(
        address _oToken,
        uint256 _optionTokenAmount,
        uint256 _wethAmount,
        bool _receiveUnderlying,
        uint256 _slippageAllowed
    ) internal {
        // exercise
        IoToken(_oToken).exercise(
            _optionTokenAmount,
            _wethAmount,
            address(this)
        );

        // pull our underlying from the oToken
        IERC20 underlying = IERC20(IoToken(_oToken).underlyingToken());
        uint256 underlyingReceived = underlying.balanceOf(address(this));

        IRouter.route[] memory tokenToWeth = new IRouter.route[](1);
        tokenToWeth[0] = IRouter.route(
            address(underlying),
            address(weth),
            false
        );

        // use this to minimize issues with slippage (swapping with too much size)
        uint256 wethPerToken = router.getAmountOut(
            1e18,
            address(underlying),
            address(weth),
            false
        );
        uint256 minAmountOut = (underlyingReceived *
            wethPerToken *
            (MAX_BPS - _slippageAllowed)) / (1e18 * MAX_BPS);

        // use this amount to calculate fees
        uint256 totalWeth;
        uint256[] memory amounts;

        if (_receiveUnderlying) {
            // simulate our swap to calc WETH needed for fee + repay flashloan
            amounts = router.getAmountsOut(_optionTokenAmount, tokenToWeth);
            totalWeth = amounts[1];
            uint256 feeAmount = (totalWeth * fee) / MAX_BPS;
            minAmountOut = feeAmount + _wethAmount;

            // calculate how much underlying we need to get at least this much WETH

            // then do our wBLT -> underlying step
            address[] memory underlyingToWETH = new address[](2);
            underlyingToWETH[0] = address(underlying);
            underlyingToWETH[1] = address(weth);
            amounts = getAmountsIn(minAmountOut, underlyingToWETH);
            uint256 underlyingToSwap = amounts[0];

            // swap our underlying amount calculated above
            router.swapExactTokensForTokens(
                underlyingToSwap,
                minAmountOut,
                tokenToWeth,
                address(this),
                block.timestamp
            );

            // take fees
            _takeFees(totalWeth);
        } else {
            // use our router to swap from underlying to WETH
            amounts = router.swapExactTokensForTokens(
                underlyingReceived,
                minAmountOut,
                tokenToWeth,
                address(this),
                block.timestamp
            );
            totalWeth = amounts[1];

            // take fees normally since we're doing all to WETH
            _takeFees(totalWeth);
        }
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
     *  Update fee for oToken -> WETH conversion.
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

    // given an output amount of an asset and pair reserves, returns a required input amount of the other asset
    // assumes 0.3% fee
    function getAmountIn(
        uint amountOut,
        uint reserveIn,
        uint reserveOut
    ) internal pure returns (uint amountIn) {
        require(amountOut > 0, "getAmountIn: amountOut must be >0");
        require(
            reserveIn > 0 && reserveOut > 0,
            "getAmountIn: Reserves must both be >0"
        );
        uint numerator = reserveIn * amountOut * 1000;
        uint denominator = (reserveOut - amountOut) * 997;
        amountIn = (numerator / denominator) + 1;
    }

    // performs chained getAmountIn calculations on any number of pairs
    // just pass addresses directly since we won't use stable pools
    function getAmountsIn(
        uint amountOut,
        address[] memory path
    ) public view returns (uint[] memory amounts) {
        require(path.length >= 2, "getAmountsIn: Path length must be >1");
        amounts = new uint[](path.length);
        amounts[amounts.length - 1] = amountOut;
        for (uint i = path.length - 1; i > 0; i--) {
            (uint reserveIn, uint reserveOut) = router.getReserves(
                path[i - 1],
                path[i],
                false
            );
            amounts[i - 1] = getAmountIn(amounts[i], reserveIn, reserveOut);
        }
    }

    // helper to approve new oTokens to spend tokens from this contract
    function _checkAllowance(address _oToken) internal {
        if (weth.allowance(address(this), _oToken) == 0) {
            weth.approve(_oToken, type(uint256).max);

            // approve router to spend underlying from this contract
            IERC20 underlying = IERC20(IoToken(_oToken).underlyingToken());
            underlying.approve(address(router), type(uint256).max);
        }
    }

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
