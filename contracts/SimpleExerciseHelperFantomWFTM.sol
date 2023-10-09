// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.19;

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

    function getPaymentTokenAmountForExerciseLp(
        uint256 _amount,
        uint256 _discount
    )
        external
        view
        returns (uint256 paymentAmount, uint256 paymentAmountToAddLiquidity);

    function exerciseLp(
        uint256 _amount,
        uint256 _maxPaymentAmount,
        address _recipient,
        uint256 _discount,
        uint256 _deadline
    ) external returns (uint256, uint256);
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

    function quoteAddLiquidity(
        address tokenA,
        address tokenB,
        bool stable,
        uint amountADesired,
        uint amountBDesired
    ) external view returns (uint amountA, uint amountB, uint liquidity);

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
 * @title Simple Exercise Helper Fantom WFTM
 * @notice This contract easily converts oTokens on Fantom that are paired with WFTM
 *  (such as oFVM) to WFTM, underlying, or underlying-WFTM LP token using flash loans.
 */

contract SimpleExerciseHelperFantomWFTM is Ownable2Step {
    /// @notice WFTM, payment token
    IERC20 internal constant wftm =
        IERC20(0x21be370D5312f44cB42ce377BC9b8a0cEF1A4C83);

    /// @notice Flashloan from Balancer vault
    IBalancer internal constant balancerVault =
        IBalancer(0x20dd72Ed959b6147912C2e529F0a0C651c33c9ce);

    /// @notice FVM router for swaps
    IRouter internal constant router =
        IRouter(0x2E14B53E2cB669f3A974CeaF6C735e134F3Aa9BC);

    /// @notice Check whether we are in the middle of a flashloan (used for callback)
    bool public flashEntered;

    /// @notice Where we send our 0.25% fee
    address public feeAddress = 0x58761D6C6bF6c4bab96CaE125a2e5c8B1859b48a;

    uint256 public fee = 25;

    uint256 internal constant MAX_BPS = 10_000;
    uint256 internal constant DISCOUNT_DENOMINATOR = 100;

    /**
     * @notice Check if spot swap price and exercising are similar enough for our liking.
     * @param _oToken The option token we are exercising.
     * @param _optionTokenAmount The amount of oToken to exercise to WFTM.
     * @param _profitSlippageAllowed Considers effect of TWAP vs spot pricing of options
     *  on profit outcomes.
     * @return wftmNeeded How much WFTM is needed for given amount of oToken.
     * @return withinSlippageTolerance Whether expected vs real profit fall within our
     *  slippage tolerance.
     * @return realProfit Simulated profit in WFTM after repaying flash loan.
     * @return expectedProfit Calculated ideal profit based on redemption discount plus
     *  allowed slippage.
     * @return profitSlippage Expected profit slippage with given oToken amount, 18
     *  decimals. Zero means extra profit (positive slippage).
     */
    function quoteExerciseProfit(
        address _oToken,
        uint256 _optionTokenAmount,
        uint256 _profitSlippageAllowed
    )
        public
        view
        returns (
            uint256 wftmNeeded,
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

        // calculate how much WFTM we need for our oToken amount
        wftmNeeded = IoToken(_oToken).getDiscountedPrice(_optionTokenAmount);

        // compare our WFTM needed to spot price
        uint256 wftmReceived = router.getAmountOut(
            _optionTokenAmount,
            IoToken(_oToken).underlyingToken(),
            address(wftm),
            false
        );
        uint256 estimatedFee = (wftmReceived * fee) / MAX_BPS;

        // make sure we don't spend more than we have
        if (wftmNeeded > wftmReceived - estimatedFee) {
            revert("Cost exceeds profit");
        } else {
            realProfit = wftmReceived - wftmNeeded - estimatedFee;
        }

        // calculate our ideal profit using the discount and known wftmNeeded
        uint256 discount = IoToken(_oToken).discount();
        expectedProfit =
            ((wftmNeeded * (DISCOUNT_DENOMINATOR - discount)) / discount) -
            estimatedFee;

        // if profitSlippage returns zero, we have positive slippage (extra profit)
        if (expectedProfit > realProfit) {
            profitSlippage = 1e18 - ((realProfit * 1e18) / expectedProfit);
        }

        // allow for our expected slippage as well
        expectedProfit =
            (expectedProfit * (MAX_BPS - _profitSlippageAllowed)) /
            MAX_BPS;

        // check if real profit is greater than expected when allowing for slippage
        if (realProfit > expectedProfit) {
            withinSlippageTolerance = true;
        }
    }

    /**
     * @notice Check if spot swap price and exercising are similar enough for our liking.
     * @param _oToken The option token we are exercising.
     * @param _optionTokenAmount The amount of oToken to exercise to underlying.
     * @param _profitSlippageAllowed Considers effect of TWAP vs spot pricing of options
     *  on profit outcomes.
     * @return wftmNeeded How much WFTM is needed for given amount of oToken.
     * @return withinSlippageTolerance Whether expected vs real profit fall within our
     *  slippage tolerance.
     * @return realProfit Simulated profit in underlying after repaying flash loan.
     * @return expectedProfit Calculated ideal profit based on redemption discount plus
     *  allowed slippage.
     * @return profitSlippage Expected profit slippage with given oToken amount, 18
     *  decimals. Zero means extra profit (positive slippage).
     */
    function quoteExerciseToUnderlying(
        address _oToken,
        uint256 _optionTokenAmount,
        uint256 _profitSlippageAllowed
    )
        public
        view
        returns (
            uint256 wftmNeeded,
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

        // calculate how much WFTM we need for our oToken amount
        wftmNeeded = IoToken(_oToken).getDiscountedPrice(_optionTokenAmount);

        // simulate swapping all to WFTM to better estimate total WFTM needed
        address underlying = IoToken(_oToken).underlyingToken();
        uint256 minAmount = router.getAmountOut(
            _optionTokenAmount,
            underlying,
            address(wftm),
            false
        );
        minAmount = wftmNeeded + (minAmount * fee) / MAX_BPS;

        // calculate how much underlying we need to get at least this much WFTM
        address[] memory underlyingToWftmAddress = new address[](2);
        underlyingToWftmAddress[0] = underlying;
        underlyingToWftmAddress[1] = address(wftm);
        uint256[] memory amounts = getAmountsIn(
            minAmount,
            underlyingToWftmAddress
        );
        minAmount = amounts[0];

        // make sure exercising is profitable
        if (minAmount > _optionTokenAmount) {
            revert("Cost exceeds profit");
        } else {
            realProfit = _optionTokenAmount - minAmount;
        }

        // calculate our real and expected profit
        expectedProfit =
            (_optionTokenAmount *
                ((MAX_BPS *
                    (DISCOUNT_DENOMINATOR - IoToken(_oToken).discount())) /
                    DISCOUNT_DENOMINATOR -
                    fee)) /
            MAX_BPS;

        // if profitSlippage returns zero, we have positive slippage (extra profit)
        if (expectedProfit > realProfit) {
            profitSlippage = 1e18 - ((realProfit * 1e18) / expectedProfit);
        }

        // allow for our expected slippage as well
        expectedProfit =
            (expectedProfit * (MAX_BPS - _profitSlippageAllowed)) /
            MAX_BPS;

        // check if real profit is greater than expected when allowing for slippage
        if (realProfit > expectedProfit) {
            withinSlippageTolerance = true;
        }
    }

    /**
     * @notice Simulate our output, exercising oToken to LP, given various input
     *  parameters. Any extra is sent to user as underlying.
     * @dev Returned lpAmountOut matches exactly with simulating an oToken exerciseLp()
     *  call. However, we slightly overestimate what will be returned by this contract's
     *  exerciseToLp() due to changing the blockchain state with multiple swaps prior to
     *  the final oToken exerciseLp() call. Note that this overestimation increases with
     *  _optionTokenAmount and decreases when minimizing underlyingOut, but typically is
     *  lower than 1%.
     * @param _oToken The option token we are exercising.
     * @param _optionTokenAmount The amount of oToken to exercise to LP.
     * @param _profitSlippageAllowed Considers effect of TWAP vs spot pricing of options
     *  on profit outcomes.
     * @param _percentToLp Out of 10,000. How much our oToken should we send to exercise
     *  for LP?
     * @param _discount Our discount percentage for LP. How long do we want to lock for?
     * @return withinSlippageTolerance Whether expected vs real profit fall within our
     *  slippage tolerance.
     * @return lpAmountOut Simulated amount of LP token to receive.
     * @return underlyingOut Simulated amount of underlying to receive.
     * @return profitSlippage Expected profit slippage with given oToken amount, 18
     *  decimals. Zero means extra profit (positive slippage).
     */
    function quoteExerciseLp(
        address _oToken,
        uint256 _optionTokenAmount,
        uint256 _profitSlippageAllowed,
        uint256 _percentToLp,
        uint256 _discount
    )
        public
        view
        returns (
            bool withinSlippageTolerance,
            uint256 lpAmountOut,
            uint256 underlyingOut,
            uint256 profitSlippage
        )
    {
        if (_percentToLp > 10_000) {
            revert("Percent must be < 10,000");
        }

        // correct our optionTokenAmount for our percent to LP
        uint256 oTokensToSell = (_optionTokenAmount * (10_000 - _percentToLp)) /
            10_000;

        // simulate exercising our oTokens to WFTM
        uint256 wftmAmountOut;
        (
            ,
            withinSlippageTolerance,
            wftmAmountOut,
            ,
            profitSlippage
        ) = quoteExerciseProfit(_oToken, oTokensToSell, _profitSlippageAllowed);

        // simulate using our WFTM amount to LP with our selected discount
        uint256 oTokensToLp = _optionTokenAmount - oTokensToSell;
        (uint256 paymentAmount, uint256 matchingForLp) = IoToken(_oToken)
            .getPaymentTokenAmountForExerciseLp(oTokensToLp, _discount);
        paymentAmount += matchingForLp;

        // revert if we don't have enough
        if (paymentAmount > wftmAmountOut) {
            revert("Need more WFTM, decrease _percentToLp or _discount values");
        }

        // how much LP would we get?
        address underlying = IoToken(_oToken).underlyingToken();
        (, , lpAmountOut) = router.quoteAddLiquidity(
            underlying,
            address(wftm),
            false,
            oTokensToLp,
            matchingForLp
        );

        // check how much WFTM we have remaining
        uint256 wftmOut = wftmAmountOut - paymentAmount;

        // convert remaining WFTM to underlying
        underlyingOut = router.getAmountOut(
            wftmOut,
            address(wftm),
            underlying,
            false
        );
    }

    /**
     * @notice Exercise our oToken for LP.
     * @param _oToken The option token we are exercising.
     * @param _optionTokenAmount The amount of oToken to exercise to LP.
     * @param _profitSlippageAllowed Considers effect of TWAP vs spot pricing of options
     *  on profit outcomes.
     * @param _swapSlippageAllowed Slippage (really price impact) we allow while swapping
     *  between assets.
     */
    function exerciseToLp(
        address _oToken,
        uint256 _optionTokenAmount,
        uint256 _profitSlippageAllowed,
        uint256 _swapSlippageAllowed,
        uint256 _percentToLp,
        uint256 _discount
    ) public {
        // first person does the approvals for everyone else, what a nice person!
        _checkAllowance(_oToken);

        // transfer option token to this contract
        _safeTransferFrom(
            _oToken,
            msg.sender,
            address(this),
            _optionTokenAmount
        );

        // correct our optionTokenAmount for our percent to LP
        uint256 oTokensToSell = (_optionTokenAmount * (10_000 - _percentToLp)) /
            10_000;

        // simulate exercising our oTokens to WFTM, and check slippage
        (
            uint256 wftmNeeded,
            bool withinSlippageTolerance,
            ,
            ,

        ) = quoteExerciseProfit(_oToken, oTokensToSell, _profitSlippageAllowed);

        // revert if slippage is too high
        if (!withinSlippageTolerance) {
            revert("Profit slippage higher than allowed");
        }

        // convert directly to WFTM, this is our paymentToken
        _borrowPaymentToken(
            _oToken,
            oTokensToSell,
            wftmNeeded,
            false,
            _swapSlippageAllowed
        );

        // don't worry about price impact for remaining swaps, as they should be small
        //  enough for it to be negligible, and true slippage (🥪) protection isn't
        //  possible without an external price oracle

        // exercise our remaining oTokens and lock LP with msg.sender as recipient
        uint256 oTokensToLp = _optionTokenAmount - oTokensToSell;
        IoToken(_oToken).exerciseLp(
            oTokensToLp,
            wftm.balanceOf(address(this)),
            msg.sender,
            _discount,
            block.timestamp
        );

        // convert any significant remaining WFTM to underlying
        IERC20 underlying = IERC20(IoToken(_oToken).underlyingToken());
        uint256 wftmBalance = wftm.balanceOf(address(this));
        if (wftmBalance > 5e17) {
            // swap, update wftmBalance
            router.swapExactTokensForTokensSimple(
                wftmBalance,
                0,
                address(wftm),
                address(underlying),
                false,
                address(this),
                block.timestamp
            );
            wftmBalance = wftm.balanceOf(address(this));
        }

        if (wftmBalance > 0) {
            _safeTransfer(address(wftm), msg.sender, wftmBalance);
        }

        uint256 underlyingBalance = underlying.balanceOf(address(this));
        if (underlyingBalance > 0) {
            _safeTransfer(address(underlying), msg.sender, underlyingBalance);
        }
    }

    /**
     * @notice Exercise our oToken for WFTM or underlying.
     * @param _oToken The option token we are exercising.
     * @param _amount The amount of oToken to exercise.
     * @param _receiveUnderlying Whether the user wants to receive WFTM or underlying.
     * @param _profitSlippageAllowed Considers effect of TWAP vs spot pricing of options
     *  on profit outcomes.
     * @param _swapSlippageAllowed Slippage (really price impact) we allow while
     *  exercising.
     */
    function exercise(
        address _oToken,
        uint256 _amount,
        bool _receiveUnderlying,
        uint256 _profitSlippageAllowed,
        uint256 _swapSlippageAllowed
    ) external {
        // first person does the approvals for everyone else, what a nice person!
        _checkAllowance(_oToken);

        // check that slippage tolerance for profit is okay
        (
            uint256 wftmNeeded,
            bool withinSlippageTolerance,
            ,
            ,

        ) = quoteExerciseProfit(_oToken, _amount, _profitSlippageAllowed);

        // revert if too much slippage
        if (!withinSlippageTolerance) {
            revert("Profit slippage higher than allowed");
        }

        // transfer option token to this contract
        _safeTransferFrom(_oToken, msg.sender, address(this), _amount);
        IERC20 oToken = IERC20(_oToken);

        // get our flash loan started
        _borrowPaymentToken(
            _oToken,
            oToken.balanceOf(address(this)),
            wftmNeeded,
            _receiveUnderlying,
            _swapSlippageAllowed
        );

        // don't worry about price impact for remaining swaps, as they should be small
        //  enough for it to be negligible, and true slippage (🥪) protection isn't
        //  possible without an external price oracle

        // anything remaining in the helper is pure profit
        uint256 wftmBalance = wftm.balanceOf(address(this));

        if (_receiveUnderlying) {
            // pull out our underlying token
            IERC20 underlying = IERC20(IoToken(_oToken).underlyingToken());

            // swap any significant leftover WFTM to underlying, but should just be dust
            //  left if we did our calculations properly
            if (wftmBalance > 5e17) {
                router.swapExactTokensForTokensSimple(
                    wftmBalance,
                    0,
                    address(wftm),
                    address(underlying),
                    false,
                    address(this),
                    block.timestamp
                );
                wftmBalance = wftm.balanceOf(address(this));
            }

            // send underlying to user
            uint256 underlyingBalance = underlying.balanceOf(address(this));
            if (underlyingBalance > 0) {
                _safeTransfer(
                    address(underlying),
                    msg.sender,
                    underlyingBalance
                );
            }
        }

        if (wftmBalance > 0) {
            _safeTransfer(address(wftm), msg.sender, wftmBalance);
        }
    }

    /**
     * @notice Flash loan our WFTM from Balancer.
     * @param _oToken The option token we are exercising.
     * @param _oTokenToExercise The amount of oToken we are exercising.
     * @param _wftmNeeded The amount of WFTM needed.
     * @param _receiveUnderlying Whether the user wants to receive WFTM or underlying.
     * @param _slippageAllowed Slippage (really price impact) we allow while exercising.
     */
    function _borrowPaymentToken(
        address _oToken,
        uint256 _oTokenToExercise,
        uint256 _wftmNeeded,
        bool _receiveUnderlying,
        uint256 _slippageAllowed
    ) internal {
        // change our state
        flashEntered = true;

        // create our input args
        address[] memory tokens = new address[](1);
        tokens[0] = address(wftm);

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = _wftmNeeded;

        bytes memory userData = abi.encode(
            _oToken,
            _oTokenToExercise,
            _wftmNeeded,
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
     * @param _tokens The tokens we are swapping (in our case, only WFTM).
     * @param _amounts The amounts of said tokens.
     * @param _feeAmounts The fee amounts for said tokens.
     * @param _userData Useful data passed when calling our flash loan.
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

        // pull out info from the userData
        (
            address _oToken,
            uint256 _oTokenToExercise,
            uint256 _wftmToExercise,
            bool _receiveUnderlying,
            uint256 _slippageAllowed
        ) = abi.decode(_userData, (address, uint256, uint256, bool, uint256));

        _exerciseAndSwap(
            _oToken,
            _oTokenToExercise,
            _wftmToExercise,
            _receiveUnderlying,
            _slippageAllowed
        );

        // repay our flash loan
        uint256 payback = _amounts[0] + _feeAmounts[0];
        _safeTransfer(address(wftm), address(balancerVault), payback);
        flashEntered = false;
    }

    /**
     * @notice Exercise our oToken, then swap some (or all) underlying to WFTM.
     * @param _oToken The option token we are exercising.
     * @param _optionTokenAmount Amount of oToken to exercise.
     * @param _wftmAmount Amount of WFTM needed to pay for exercising.
     * @param _receiveUnderlying Whether the user wants to receive WFTM or underlying.
     * @param _slippageAllowed Slippage (really price impact) we allow while exercising.
     */
    function _exerciseAndSwap(
        address _oToken,
        uint256 _optionTokenAmount,
        uint256 _wftmAmount,
        bool _receiveUnderlying,
        uint256 _slippageAllowed
    ) internal {
        // exercise
        IoToken(_oToken).exercise(
            _optionTokenAmount,
            _wftmAmount,
            address(this)
        );

        // pull our underlying from the oToken
        IERC20 underlying = IERC20(IoToken(_oToken).underlyingToken());
        uint256 underlyingReceived = underlying.balanceOf(address(this));

        IRouter.route[] memory underlyingToWftm = new IRouter.route[](1);
        underlyingToWftm[0] = IRouter.route(
            address(underlying),
            address(wftm),
            false
        );

        // use this to minimize issues with slippage (swapping with too much size)
        uint256 wftmPerToken = router.getAmountOut(
            1e18,
            address(underlying),
            address(wftm),
            false
        );
        uint256 minAmountOut = (underlyingReceived *
            wftmPerToken *
            (MAX_BPS - _slippageAllowed)) / (1e18 * MAX_BPS);

        // use this amount to calculate fees
        uint256 totalWftm;
        uint256[] memory amounts;

        if (_receiveUnderlying) {
            // simulate our swap to calc WFTM needed for fee + repay flashloan
            amounts = router.getAmountsOut(
                _optionTokenAmount,
                underlyingToWftm
            );
            totalWftm = amounts[1];
            uint256 feeAmount = (totalWftm * fee) / MAX_BPS;
            minAmountOut = feeAmount + _wftmAmount;

            // calculate how much underlying we need to get at least this much WFTM
            address[] memory underlyingToWftmAddresses = new address[](2);
            underlyingToWftmAddresses[0] = address(underlying);
            underlyingToWftmAddresses[1] = address(wftm);
            amounts = getAmountsIn(minAmountOut, underlyingToWftmAddresses);
            uint256 underlyingToSwap = amounts[0];

            // swap our underlying amount calculated above
            router.swapExactTokensForTokens(
                underlyingToSwap,
                minAmountOut,
                underlyingToWftm,
                address(this),
                block.timestamp
            );

            // take fees
            _takeFees(totalWftm);
        } else {
            // use our router to swap from underlying to WFTM
            amounts = router.swapExactTokensForTokens(
                underlyingReceived,
                minAmountOut,
                underlyingToWftm,
                address(this),
                block.timestamp
            );
            totalWftm = amounts[1];

            // take fees normally since we're doing all to WFTM
            _takeFees(totalWftm);
        }
    }

    /**
     * @notice Apply fees to our after-swap total.
     * @dev Default is 0.25% but this may be updated later.
     * @param _amount Amount to apply our fee to.
     */
    function _takeFees(uint256 _amount) internal {
        uint256 toSend = (_amount * fee) / MAX_BPS;
        _safeTransfer(address(wftm), feeAddress, toSend);
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
     * @notice Update fee for oToken -> WFTM conversion.
     * @param _recipient Fee recipient address.
     * @param _newFee New fee, out of 10,000.
     */
    function setFee(address _recipient, uint256 _newFee) external onlyOwner {
        if (_newFee > DISCOUNT_DENOMINATOR) {
            revert("setFee: Fee max is 1%");
        }
        fee = _newFee;
        feeAddress = _recipient;
    }

    /* ========== HELPER FUNCTIONS ========== */

    /**
     * @notice Given an output amount of an asset and pair reserves, returns a required
     *  input amount of the other asset.
     * @dev Assumes 0.3% fee.
     * @param amountOut Minimum amount we need to receive of reserveOut token.
     * @param reserveIn Pair reserve of our amountIn token.
     * @param reserveOut Pair reserve of our amountOut token.
     * @return amountIn Amount of reserveIn to swap to receive amountOut.
     */
    function getAmountIn(
        uint amountOut,
        uint reserveIn,
        uint reserveOut
    ) internal pure returns (uint amountIn) {
        if (amountOut == 0) {
            revert("getAmountIn: amountOut must be >0");
        }
        if (reserveIn == 0 || reserveOut == 0) {
            revert("getAmountIn: Reserves must be >0");
        }
        uint numerator = reserveIn * amountOut * 1000;
        uint denominator = (reserveOut - amountOut) * 997;
        amountIn = (numerator / denominator) + 1;
    }

    /**
     * @notice Performs chained getAmountIn calculations on any number of pairs.
     * @dev Assumes only volatile pools.
     * @param amountOut Minimum amount we need to receive of the final array token.
     * @param path Array of addresses for our swap path, UniV2-style.
     * @return amounts Array of amounts for each token in our swap path.
     */
    function getAmountsIn(
        uint amountOut,
        address[] memory path
    ) public view returns (uint[] memory amounts) {
        if (path.length < 2) {
            revert("getAmountsIn: Path length must be >1");
        }
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

    /**
     * @notice Helper to approve new oTokens to spend tokens from this contract
     * @dev Will only approve on first call.
     * @param _oToken Address of oToken to check for.
     */
    function _checkAllowance(address _oToken) internal {
        if (wftm.allowance(address(this), _oToken) == 0) {
            wftm.approve(_oToken, type(uint256).max);

            // approve router to spend underlying from this contract
            IERC20 underlying = IERC20(IoToken(_oToken).underlyingToken());
            underlying.approve(address(router), type(uint256).max);
            wftm.approve(address(router), type(uint256).max);
        }
    }

    /**
     * @notice Internal safeTransfer function. Transfer tokens to another address.
     * @param token Address of token to transfer.
     * @param to Address to send token to.
     * @param value Amount of token to send.
     */
    function _safeTransfer(address token, address to, uint256 value) internal {
        require(token.code.length > 0);
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(IERC20.transfer.selector, to, value)
        );
        require(success && (data.length == 0 || abi.decode(data, (bool))));
    }

    /**
     * @notice Internal safeTransferFrom function. Transfer tokens from one address to
     *  another.
     * @dev From address must have approved sufficient allowance for this contract.
     * @param token Address of token to transfer.
     * @param to Address to send token from.
     * @param to Address to send token to.
     * @param value Amount of token to send.
     */
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
