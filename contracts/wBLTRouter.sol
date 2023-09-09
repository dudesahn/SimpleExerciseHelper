// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import "./Interfaces.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";

contract wBLTRouter is Ownable2Step {
    struct route {
        address from;
        address to;
        bool stable;
    }

    /// @notice Factory address that deployed our Velodrome pool.
    address public immutable factory;

    IWETH public immutable weth;
    uint internal constant MINIMUM_LIQUIDITY = 10 ** 3;
    bytes32 immutable pairCodeHash;

    /// @notice The tokens currently approved for deposit to BLT.
    address[] public bltTokens;

    // standard Morphex contracts
    address internal constant bmx = 0x548f93779fBC992010C07467cBaf329DD5F059B7;

    VaultAPI internal constant wBLT =
        VaultAPI(0x4E74D4Db6c0726ccded4656d0BCE448876BB4C7A);

    IBMX internal constant oBMX =
        IBMX(0x3Ff7AB26F2dfD482C40bDaDfC0e88D01BFf79713);

    IBMX internal constant oracle =
        IBMX(0x03dCf91e8e5e07B563d1f2E115B2377f71fE50Aa);

    IBMX internal constant sBLT =
        IBMX(0x64755939a80BC89E1D2d0f93A312908D348bC8dE);

    IBMX internal constant rewardRouter =
        IBMX(0x49A97680938B4F1f73816d1B70C3Ab801FAd124B);

    IBMX internal constant morphexVault =
        IBMX(0xec8d8D4b215727f3476FF0ab41c406FA99b4272C);

    IBMX internal constant bltManager =
        IBMX(0x9fAc7b75f367d5B35a6D6D0a09572eFcC3D406C5);

    IBMX internal constant vaultUtils =
        IBMX(0xec31c83C5689C66cb77DdB5378852F3707022039);

    constructor(address _factory, address _weth) {
        factory = _factory;
        pairCodeHash = IPairFactory(_factory).pairCodeHash();
        weth = IWETH(_weth);

        // do approvals for wBLT
        sBLT.approve(address(wBLT), type(uint256).max);
        wBLT.approve(address(oBMX), type(uint256).max);

        // update our allowances
        updateAllowances();
    }

    modifier ensure(uint deadline) {
        require(deadline >= block.timestamp, "Router: EXPIRED");
        _;
    }

    receive() external payable {
        assert(msg.sender == address(weth)); // only accept ETH via fallback from the WETH contract
    }

    /* ========== NEW/MODIFIED FUNCTIONS ========== */

    function updateAllowances() public onlyOwner {
        // first, set all of our allowances to zero
        for (uint i = 0; i < bltTokens.length; ++i) {
            IERC20 token = IERC20(bltTokens[i]);
            token.approve(address(bltManager), 0);
        }

        // clear out our saved array
        delete bltTokens;

        // add our new tokens
        uint256 tokensCount = morphexVault.whitelistedTokenCount();
        for (uint i = 0; i < tokensCount; ++i) {
            IERC20 token = IERC20(morphexVault.allWhitelistedTokens(i));
            token.approve(address(bltManager), type(uint256).max);
            bltTokens.push(address(token));
        }
    }

    /**
     * @notice
     *  Performs chained getAmountOut calculations on any number of pairs.
     * @dev This is mainly used when conducting swaps.
     * @param amountIn The amount of our first token to swap.
     * @param routes Array of structs that we use for our swap path.
     * @return amounts Amount of each token in the swap path.
     */
    //
    function getAmountsOut(
        uint amountIn,
        route[] memory routes
    ) public view returns (uint[] memory amounts) {
        require(routes.length >= 1, "Router: INVALID_PATH");
        amounts = new uint[](routes.length + 1);
        amounts[0] = amountIn;
        for (uint i = 0; i < routes.length; i++) {
            // check if we need to convert to or from wBLT
            if (routes[i].from == address(wBLT)) {
                // check to make sure it's one of the tokens in BLT
                if (isBLTToken(routes[i].to)) {
                    amounts[i + 1] = getRedeemAmountWrappedBLT(
                        routes[i].to,
                        amounts[i]
                    );
                    continue;
                }
            } else if (routes[i].to == address(wBLT)) {
                // check to make sure it's one of the tokens in BLT
                if (isBLTToken(routes[i].from)) {
                    amounts[i + 1] = getMintAmountWrappedBLT(
                        routes[i].from,
                        amounts[i]
                    );
                    continue;
                }
            }

            // if it's not depositing or withdrawing from wBLT, we can treat it like normal
            address pair = pairFor(
                routes[i].from,
                routes[i].to,
                routes[i].stable
            );
            if (IPairFactory(factory).isPair(pair)) {
                amounts[i + 1] = IPair(pair).getAmountOut(
                    amounts[i],
                    routes[i].from
                );
            }
        }
    }

    /**
     * @notice
     *  Swap BMX or wBLT for ether.
     * @param amountIn The amount of our first token to swap.
     * @param amountOutMin Minimum amount of ether we must receive.
     * @param routes Array of structs that we use for our swap path.
     * @param to Address that will receive the ether.
     * @param deadline Deadline for transaction to complete.
     * @return amounts Amount of each token in the swap path.
     */
    function swapExactTokensForETH(
        uint amountIn,
        uint amountOutMin,
        route[] calldata routes,
        address to,
        uint deadline
    ) public payable ensure(deadline) returns (uint[] memory amounts) {
        // tbh just do this manually, becuase realistically you're only using this to swap from wBLT or BMX
        amounts = getAmountsOut(amountIn, routes);
        require(
            amounts[amounts.length - 1] >= amountOutMin,
            "Router: INSUFFICIENT_OUTPUT_AMOUNT"
        );

        // if wBLT, just transfer it in
        if (routes[0].from == address(wBLT)) {
            _safeTransferFrom(
                routes[0].from,
                msg.sender,
                address(this),
                amounts[0]
            );
        } else if (routes[0].from == bmx) {
            address wBLTPair = 0xd272920B2b4eBeE362a887451EDBd6d68A76E507;
            _safeTransferFrom(routes[0].from, msg.sender, wBLTPair, amounts[0]);

            // swap directly on our pair, BMX -> wBLT and back to this router
            IPair(wBLTPair).swap(amounts[1], 0, address(this), new bytes(0));
        } else {
            revert("Only BMX or wBLT to ETH");
        }

        // wBLT -> WETH -> ETH
        uint256 withdrawnAmount = _withdrawFromWrappedBLT(address(weth));
        weth.withdraw(withdrawnAmount);
        _safeTransferETH(to, withdrawnAmount);
    }

    /**
     * @notice
     *  Swap ETH for tokens, with special handling for BMX and wBLT.
     * @param amountIn The amount of ether to swap.
     * @param amountOutMin Minimum amount of our final token we must receive.
     * @param routes Array of structs that we use for our swap path.
     * @param to Address that will receive the final token in the swap path.
     * @param deadline Deadline for transaction to complete.
     * @return amounts Amount of each token in the swap path.
     */
    function swapExactETHForTokens(
        uint amountIn,
        uint amountOutMin,
        route[] calldata routes,
        address to,
        uint deadline
    ) public payable ensure(deadline) returns (uint[] memory amounts) {
        amounts = getAmountsOut(amountIn, routes);
        require(
            amounts[amounts.length - 1] >= amountOutMin,
            "Router: INSUFFICIENT_OUTPUT_AMOUNT"
        );

        // deposit to weth first
        weth.deposit{value: amountIn}();
        if (weth.balanceOf(address(this)) != amountIn) {
            revert("WETH not sent");
        }

        if (routes[0].from != address(weth) || routes[0].to != address(wBLT)) {
            revert("Route must start WETH -> wBLT");
        }

        _swap(amounts, routes, to);
    }

    /**
     * @notice
     *  Swap tokens for tokens, with special handling for BMX and wBLT.
     * @param amountIn The amount of our first token to swap.
     * @param amountOutMin Minimum amount of our final token we must receive.
     * @param routes Array of structs that we use for our swap path.
     * @param to Address that will receive the final token in the swap path.
     * @param deadline Deadline for transaction to complete.
     * @return amounts Amount of each token in the swap path.
     */
    function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        route[] calldata routes,
        address to,
        uint deadline
    ) external ensure(deadline) returns (uint[] memory amounts) {
        amounts = getAmountsOut(amountIn, routes);
        require(
            amounts[amounts.length - 1] >= amountOutMin,
            "Router: INSUFFICIENT_OUTPUT_AMOUNT"
        );

        // if our first pair is mint/burn of wBLT, transfer to the router
        if (routes[0].from == address(wBLT) || routes[0].to == address(wBLT)) {
            if (isBLTToken(routes[0].from) || isBLTToken(routes[0].to)) {
                _safeTransferFrom(
                    routes[0].from,
                    msg.sender,
                    address(this),
                    amounts[0]
                );
            } else {
                // if it's not wBLT AND an underlying, it's just a normal wBLT swap (likely w/ BMX)
                _safeTransferFrom(
                    routes[0].from,
                    msg.sender,
                    pairFor(routes[0].from, routes[0].to, routes[0].stable),
                    amounts[0]
                );
            }
        } else {
            _safeTransferFrom(
                routes[0].from,
                msg.sender,
                pairFor(routes[0].from, routes[0].to, routes[0].stable),
                amounts[0]
            );
        }

        _swap(amounts, routes, to);
    }

    // **** SWAP ****
    // requires the initial amount to have already been sent to the first pair
    // or in this case, our underlying or wBLT to have been sent to the router
    function _swap(
        uint[] memory amounts,
        route[] memory routes,
        address _to
    ) internal virtual {
        for (uint i = 0; i < routes.length; i++) {
            (address token0, ) = sortTokens(routes[i].from, routes[i].to);
            uint amountOut = amounts[i + 1];
            (uint amount0Out, uint amount1Out) = routes[i].from == token0
                ? (uint(0), amountOut)
                : (amountOut, uint(0));

            // only if we're doing a wBLT deposit/withdrawal in the middle of a route
            bool directSend;
            uint256 received;
            address to;

            // check if we need to convert to or from wBLT
            if (routes[i].from == address(wBLT)) {
                // check to see if it's one of the tokens in BLT
                if (isBLTToken(routes[i].to)) {
                    received = _withdrawFromWrappedBLT(routes[i].to);
                    if (i < (routes.length - 1)) {
                        // if we're not done, directly send our underlying to the next pair
                        directSend = true;
                    } else {
                        // if this is the last token, send to our _to address
                        _safeTransfer(routes[i].to, _to, received);
                        return;
                    }
                }
            } else if (routes[i].to == address(wBLT)) {
                // check to make sure it's one of the tokens in BLT
                if (isBLTToken(routes[i].from)) {
                    received = _depositToWrappedBLT(routes[i].from);
                    if (i < (routes.length - 1)) {
                        // if we're not done, directly send our wBLT to the next pair
                        directSend = true;
                    } else {
                        // if this is the last token, send to our _to address
                        _safeTransfer(routes[i].to, _to, received);
                        return;
                    }
                }
            }

            if (i == routes.length - 1) {
                // end of the route, send to the receiver
                to = _to;
            } else if (
                (isBLTToken(routes[i + 1].from) &&
                    routes[i + 1].to == address(wBLT)) ||
                (isBLTToken(routes[i + 1].to) &&
                    routes[i + 1].from == address(wBLT))
            ) {
                // if we're about to go underlying -> wBLT or wBLT -> underlying, then make sure we get our needed token back to the router
                to = address(this);
            } else {
                // normal mid-route swap
                to = pairFor(
                    routes[i + 1].from,
                    routes[i + 1].to,
                    routes[i + 1].stable
                );
            }

            if (directSend) {
                _safeTransfer(routes[i].to, to, received);
            } else {
                IPair(pairFor(routes[i].from, routes[i].to, routes[i].stable))
                    .swap(amount0Out, amount1Out, to, new bytes(0));
            }
        }
    }

    /**
     * @notice
     *  Add liquidity for wBLT-TOKEN with an underlying token for wBLT.
     * @dev Removed the stable and tokenA params from the standard function
     *  as they're not needed and so stack isn't too deep.
     * @param underlyingToken The token to zap into wBLT for creating the LP.
     * @param amountToZapIn Amount of underlying token to deposit to wBLT.
     * @param token The token to pair with wBLT for the LP.
     * @param amountWrappedBLTDesired The amount of wBLT we would like to deposit to the LP.
     * @param amountTokenDesired The amount of other token we would like to deposit to the LP.
     * @param amountWrappedBLTMin The minimum amount of wBLT we will accept in the LP.
     * @param amountTokenMin The minimum amount of other token we will accept in the LP.
     * @param to Address that will receive the LP token.
     * @return amountWrappedBLT Amount of wBLT actually deposited in the LP.
     * @return amountToken Amount of our other token actually deposited in the LP.
     * @return liquidity Amount of LP token generated.
     */
    function addLiquidity(
        address underlyingToken,
        uint amountToZapIn,
        address token,
        uint amountWrappedBLTDesired,
        uint amountTokenDesired,
        uint amountWrappedBLTMin,
        uint amountTokenMin,
        address to
    )
        external
        returns (uint amountWrappedBLT, uint amountToken, uint liquidity)
    {
        _safeTransferFrom(
            underlyingToken,
            msg.sender,
            address(this),
            amountToZapIn
        );

        // first, deposit the underlying to wBLT, deposit function checks that underlying is actually in the LP
        amountWrappedBLTDesired = _depositToWrappedBLT(underlyingToken);

        (amountWrappedBLT, amountToken) = _addLiquidity(
            address(wBLT),
            token,
            false, // stable LPs with wBLT would be kind dumb
            amountWrappedBLTDesired,
            amountTokenDesired,
            amountWrappedBLTMin,
            amountTokenMin
        );
        address pair = pairFor(address(wBLT), token, false);

        // wBLT will already be in the router, so transfer for it. transferFrom for other token.
        _safeTransfer(address(wBLT), pair, amountWrappedBLT);
        _safeTransferFrom(token, msg.sender, pair, amountToken);

        liquidity = IPair(pair).mint(to);
        uint256 remainingBalance = wBLT.balanceOf(address(this));
        // return any leftover wBLT
        if (remainingBalance > 0) {
            _safeTransfer(address(wBLT), msg.sender, remainingBalance);
        }
    }

    /**
     * @notice
     *  Add liquidity for wBLT-TOKEN with ether.
     * @param amountToZapIn Amount of ether to deposit to wBLT.
     * @param token The token to pair with wBLT for the LP.
     * @param amountWrappedBLTDesired The amount of wBLT we would like to deposit to the LP.
     * @param amountTokenDesired The amount of other token we would like to deposit to the LP.
     * @param amountWrappedBLTMin The minimum amount of wBLT we will accept in the LP.
     * @param amountTokenMin The minimum amount of other token we will accept in the LP.
     * @param to Address that will receive the LP token.
     * @return amountWrappedBLT Amount of wBLT actually deposited in the LP.
     * @return amountToken Amount of our other token actually deposited in the LP.
     * @return liquidity Amount of LP token generated.
     */
    function addLiquidityETH(
        uint amountToZapIn,
        address token,
        uint amountWrappedBLTDesired,
        uint amountTokenDesired,
        uint amountWrappedBLTMin,
        uint amountTokenMin,
        address to
    )
        external
        payable
        returns (uint amountWrappedBLT, uint amountToken, uint liquidity)
    {
        // deposit to weth, then everything is the same
        weth.deposit{value: amountToZapIn}();
        if (weth.balanceOf(address(this)) != amountToZapIn) {
            revert("WETH not sent");
        }

        // first, deposit the underlying to wBLT, deposit function checks that underlying is actually in the LP
        amountWrappedBLTDesired = _depositToWrappedBLT(address(weth));

        (amountWrappedBLT, amountToken) = _addLiquidity(
            address(wBLT),
            token,
            false, // stable LPs with wBLT would be kind dumb
            amountWrappedBLTDesired,
            amountTokenDesired,
            amountWrappedBLTMin,
            amountTokenMin
        );
        address pair = pairFor(address(wBLT), token, false);

        // wBLT will already be in the router, so transfer for it. transferFrom for other token.
        _safeTransfer(address(wBLT), pair, amountWrappedBLT);
        _safeTransferFrom(token, msg.sender, pair, amountToken);
        liquidity = IPair(pair).mint(to);

        // return any leftover wBLT
        uint256 remainingBalance = wBLT.balanceOf(address(this));
        if (remainingBalance > 0) {
            _safeTransfer(address(wBLT), msg.sender, remainingBalance);
        }
    }

    /**
     * @notice
     *  Remove liquidity from a wBLT-TOKEN LP, and convert wBLT to a given underlying.
     * @param targetToken Address of our desired wBLT underlying to withdraw to.
     * @param token The other token paired with wBLT in our LP.
     * @param liquidity The amount of LP tokens we want to burn.
     * @param amountWrappedBLTMin The minimum amount of wBLT we will accept from the LP.
     * @param amountTokenMin The minimum amount of our other token we will accept from the LP.
     * @param to Address that will receive the LP token.
     * @return amountWrappedBLT Amount of wBLT actually received from the LP.
     * @return amountToken Amount of other token actually received from the LP.
     * @return withdrawnAmount Amount of our underlying token received from the wBLT.
     */
    function removeLiquidity(
        address targetToken,
        address token,
        uint liquidity,
        uint amountWrappedBLTMin,
        uint amountTokenMin,
        address to
    )
        external
        returns (
            uint amountWrappedBLT,
            uint amountToken,
            uint256 withdrawnAmount
        )
    {
        address pair = pairFor(address(wBLT), token, false); // stable is dumb with wBLT
        require(IPair(pair).transferFrom(msg.sender, pair, liquidity)); // send liquidity to pair
        (uint amount0, uint amount1) = IPair(pair).burn(address(this));
        (address token0, ) = sortTokens(address(wBLT), token);
        (amountWrappedBLT, amountToken) = address(wBLT) == token0
            ? (amount0, amount1)
            : (amount1, amount0);
        require(
            amountWrappedBLT >= amountWrappedBLTMin,
            "Router: INSUFFICIENT_A_AMOUNT"
        );
        require(amountToken >= amountTokenMin, "Router: INSUFFICIENT_B_AMOUNT");

        _safeTransfer(token, to, amountToken);

        withdrawnAmount = _withdrawFromWrappedBLT(targetToken);
        _safeTransfer(targetToken, to, withdrawnAmount);
    }

    /**
     * @notice
     *  Remove liquidity from a wBLT-TOKEN LP, and convert wBLT to ether.
     * @param token The other token paired with wBLT in our LP.
     * @param liquidity The amount of LP tokens we want to burn.
     * @param amountWrappedBLTMin The minimum amount of wBLT we will accept from the LP.
     * @param amountTokenMin The minimum amount of our other token we will accept from the LP.
     * @param to Address that will receive the LP token.
     * @return amountWrappedBLT Amount of wBLT actually received from the LP.
     * @return amountToken Amount of other token actually received from the LP.
     * @return withdrawnAmount Amount of ether received from the wBLT.
     */
    function removeLiquidityETH(
        address token,
        uint liquidity,
        uint amountWrappedBLTMin,
        uint amountTokenMin,
        address to
    )
        external
        returns (
            uint amountWrappedBLT,
            uint amountToken,
            uint256 withdrawnAmount
        )
    {
        address pair = pairFor(address(wBLT), token, false); // stable is dumb with wBLT
        require(IPair(pair).transferFrom(msg.sender, pair, liquidity)); // send liquidity to pair
        (uint amount0, uint amount1) = IPair(pair).burn(address(this));
        (address token0, ) = sortTokens(address(wBLT), token);
        (amountWrappedBLT, amountToken) = address(wBLT) == token0
            ? (amount0, amount1)
            : (amount1, amount0);
        require(
            amountWrappedBLT >= amountWrappedBLTMin,
            "Router: INSUFFICIENT_A_AMOUNT"
        );
        require(amountToken >= amountTokenMin, "Router: INSUFFICIENT_B_AMOUNT");

        // send our ether and token to their final destination
        _safeTransfer(token, to, amountToken);
        withdrawnAmount = _withdrawFromWrappedBLT(address(weth));
        weth.withdraw(withdrawnAmount);
        _safeTransferETH(to, withdrawnAmount);
    }

    /**
     * @notice
     *  Exercise our oBMX options using one of wBLT's underlying tokens.
     * @param _tokenToUse Address of our desired wBLT underlying to use for exercising our option.
     * @param _amount The amount of our token to use to generate our wBLT for exercising.
     * @param _oTokenAmount The amount of option tokens to exercise.
     * @param _discount Our discount in exercising the option; this determines our lockup time.
     * @param _deadline Deadline for transaction to complete.
     * @return paymentAmount How much wBLT we spend to exercise.
     * @return lpAmount Amount of our LP we generate.
     */
    function exerciseLpWithUnderlying(
        address _tokenToUse,
        uint256 _amount,
        uint256 _oTokenAmount,
        uint256 _discount,
        uint256 _deadline
    ) external returns (uint256 paymentAmount, uint256 lpAmount) {
        _safeTransferFrom(_tokenToUse, msg.sender, address(this), _amount);

        _safeTransferFrom(
            address(oBMX),
            msg.sender,
            address(this),
            _oTokenAmount
        );
        uint256 wBltToLp = _depositToWrappedBLT(_tokenToUse);

        (paymentAmount, lpAmount) = oBMX.exerciseLp(
            _oTokenAmount,
            wBltToLp,
            msg.sender,
            _discount,
            _deadline
        );

        // return any leftover wBLT or underlying
        IERC20 token = IERC20(_tokenToUse);
        uint256 remainingUnderlying = token.balanceOf(address(this));
        uint256 remainingBalance = wBLT.balanceOf(address(this));

        if (remainingBalance > 0) {
            _safeTransfer(address(wBLT), msg.sender, remainingBalance);
        }

        if (remainingUnderlying > 0) {
            _safeTransfer(_tokenToUse, msg.sender, remainingUnderlying);
        }
    }

    /**
     * @notice
     *  Exercise our oBMX options using raw ether.
     * @param _amount The amount of our token to use to generate our wBLT for exercising.
     * @param _oTokenAmount The amount of option tokens to exercise.
     * @param _discount Our discount in exercising the option; this determines our lockup time.
     * @param _deadline Deadline for transaction to complete.
     * @return paymentAmount How much wBLT we spend to exercise.
     * @return lpAmount Amount of our LP we generate.
     */
    function exerciseLpWithUnderlyingETH(
        uint256 _amount,
        uint256 _oTokenAmount,
        uint256 _discount,
        uint256 _deadline
    ) external payable returns (uint256 paymentAmount, uint256 lpAmount) {
        // deposit to weth, then everything is the same
        weth.deposit{value: _amount}();
        if (weth.balanceOf(address(this)) != _amount) {
            revert("WETH not sent");
        }

        // pull oBMX
        _safeTransferFrom(
            address(oBMX),
            msg.sender,
            address(this),
            _oTokenAmount
        );

        // deposit our WETH to wBLT
        uint256 wBltToLp = _depositToWrappedBLT(address(weth));

        // exercise as normal
        (paymentAmount, lpAmount) = oBMX.exerciseLp(
            _oTokenAmount,
            wBltToLp,
            msg.sender,
            _discount,
            _deadline
        );

        // return any leftover wBLT or WETH
        uint256 remainingUnderlying = weth.balanceOf(address(this));
        uint256 remainingBalance = wBLT.balanceOf(address(this));

        if (remainingBalance > 0) {
            _safeTransfer(address(wBLT), msg.sender, remainingBalance);
        }

        if (remainingUnderlying > 0) {
            _safeTransfer(address(weth), msg.sender, remainingUnderlying);
        }
    }

    function getMintAmountWrappedBLT(
        address _token,
        uint256 _amount
    ) public view returns (uint256) {
        require(_amount > 0, "invalid _amount");

        // calculate aum before buyUSDG
        uint256 aumInUsdg = bltManager.getAumInUsdg(true);
        uint256 bltSupply = sBLT.totalSupply();

        uint256 price = morphexVault.getMinPrice(_token);

        uint256 usdgAmount = (_amount * price) / morphexVault.PRICE_PRECISION();
        usdgAmount = morphexVault.adjustForDecimals(
            usdgAmount,
            _token,
            morphexVault.usdg()
        );

        uint256 feeBasisPoints = vaultUtils.getBuyUsdgFeeBasisPoints(
            _token,
            usdgAmount
        );
        uint256 afterFeeAmount = (_amount *
            (morphexVault.BASIS_POINTS_DIVISOR() - feeBasisPoints)) /
            morphexVault.BASIS_POINTS_DIVISOR();

        uint256 usdgMintAmount = (afterFeeAmount * price) /
            morphexVault.PRICE_PRECISION();
        usdgMintAmount = morphexVault.adjustForDecimals(
            usdgMintAmount,
            _token,
            morphexVault.usdg()
        );
        uint256 bltMintAmount = aumInUsdg == 0
            ? usdgMintAmount
            : (usdgMintAmount * bltSupply) / aumInUsdg;

        return bltMintAmount;
    }

    function getRedeemAmountWrappedBLT(
        address _tokenOut,
        uint256 _bltAmount
    ) public view returns (uint256) {
        require(_bltAmount > 0, "invalid _amount");

        // calculate aum before sellUSDG
        uint256 aumInUsdg = bltManager.getAumInUsdg(false);
        uint256 bltSupply = sBLT.totalSupply();
        uint256 usdgAmount = (_bltAmount * aumInUsdg) / bltSupply;

        uint256 price = morphexVault.getMaxPrice(_tokenOut);

        uint256 redeemAmount = (usdgAmount * morphexVault.PRICE_PRECISION()) /
            price;
        redeemAmount = morphexVault.adjustForDecimals(
            redeemAmount,
            morphexVault.usdg(),
            _tokenOut
        );

        uint256 feeBasisPoints = vaultUtils.getSellUsdgFeeBasisPoints(
            _tokenOut,
            usdgAmount
        );
        uint256 afterFeeAmount = (redeemAmount *
            (morphexVault.BASIS_POINTS_DIVISOR() - feeBasisPoints)) /
            morphexVault.BASIS_POINTS_DIVISOR();

        return afterFeeAmount;
    }

    // check our array,
    function isBLTToken(address _tokenToCheck) internal view returns (bool) {
        for (uint i = 0; i < bltTokens.length; ++i) {
            if (bltTokens[i] == _tokenToCheck) {
                return true;
            }
        }
        return false;
    }

    function _withdrawFromWrappedBLT(
        address _targetToken
    ) internal returns (uint256) {
        if (!isBLTToken(_targetToken)) {
            revert("Token not in wBLT");
        }

        // withdraw from the vault first, make sure it comes here
        uint256 toWithdraw = wBLT.withdraw(type(uint256).max, address(this));

        // withdraw our targetToken
        return
            rewardRouter.unstakeAndRedeemGlp(
                _targetToken,
                toWithdraw,
                0,
                address(this)
            );
    }

    function _depositToWrappedBLT(
        address _fromToken
    ) internal returns (uint256 tokens) {
        if (!isBLTToken(_fromToken)) {
            revert("Token not in wBLT");
        }

        // deposit to BLT and then the vault
        IERC20 token = IERC20(_fromToken);
        uint256 newMlp = rewardRouter.mintAndStakeGlp(
            address(_fromToken),
            token.balanceOf(address(this)),
            0,
            0
        );

        // specify that router should get the vault tokens
        tokens = wBLT.deposit(newMlp, address(this));
    }

    /* ========== UNMODIFIED FUNCTIONS ========== */

    // calculates the CREATE2 address for a pair without making any external calls
    function pairFor(
        address tokenA,
        address tokenB,
        bool stable
    ) public view returns (address pair) {
        (address token0, address token1) = sortTokens(tokenA, tokenB);
        pair = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            hex"ff",
                            factory,
                            keccak256(abi.encodePacked(token0, token1, stable)),
                            pairCodeHash // init code hash
                        )
                    )
                )
            )
        );
    }

    function sortTokens(
        address tokenA,
        address tokenB
    ) public pure returns (address token0, address token1) {
        require(tokenA != tokenB, "Router: IDENTICAL_ADDRESSES");
        (token0, token1) = tokenA < tokenB
            ? (tokenA, tokenB)
            : (tokenB, tokenA);
        require(token0 != address(0), "Router: ZERO_ADDRESS");
    }

    // fetches and sorts the reserves for a pair
    function getReserves(
        address tokenA,
        address tokenB,
        bool stable
    ) public view returns (uint reserveA, uint reserveB) {
        (address token0, ) = sortTokens(tokenA, tokenB);
        (uint reserve0, uint reserve1, ) = IPair(
            pairFor(tokenA, tokenB, stable)
        ).getReserves();
        (reserveA, reserveB) = tokenA == token0
            ? (reserve0, reserve1)
            : (reserve1, reserve0);
    }

    // determine whether to use stable or volatile pools for a given pair of tokens
    function getAmountOut(
        uint amountIn,
        address tokenIn,
        address tokenOut
    ) public view returns (uint amount, bool stable) {
        address pair = pairFor(tokenIn, tokenOut, true);
        uint amountStable;
        uint amountVolatile;
        if (IPairFactory(factory).isPair(pair)) {
            amountStable = IPair(pair).getAmountOut(amountIn, tokenIn);
        }
        pair = pairFor(tokenIn, tokenOut, false);
        if (IPairFactory(factory).isPair(pair)) {
            amountVolatile = IPair(pair).getAmountOut(amountIn, tokenIn);
        }
        return
            amountStable > amountVolatile
                ? (amountStable, true)
                : (amountVolatile, false);
    }

    //@override
    //getAmountOut	:	bool stable
    //Gets exact output for specific pair-type(S|V)
    function getAmountOut(
        uint amountIn,
        address tokenIn,
        address tokenOut,
        bool stable
    ) public view returns (uint amount) {
        address pair = pairFor(tokenIn, tokenOut, stable);
        if (IPairFactory(factory).isPair(pair)) {
            amount = IPair(pair).getAmountOut(amountIn, tokenIn);
        }
    }

    function isPair(address pair) external view returns (bool) {
        return IPairFactory(factory).isPair(pair);
    }

    // given some amount of an asset and pair reserves, returns an equivalent amount of the other asset
    function quoteLiquidity(
        uint amountA,
        uint reserveA,
        uint reserveB
    ) internal pure returns (uint amountB) {
        require(amountA > 0, "Router: INSUFFICIENT_AMOUNT");
        require(reserveA > 0 && reserveB > 0, "Router: INSUFFICIENT_LIQUIDITY");
        amountB = (amountA * reserveB) / reserveA;
    }

    function quoteMintAmountBLT(
        address _underlyingToken,
        uint256 _bltAmountNeeded
    ) public view returns (uint256) {
        require(_bltAmountNeeded > 0, "invalid _amount");

        uint256 usdgNeeded = (_bltAmountNeeded * oracle.getLivePrice()) / 1e18;
        uint256 tokenPrice = morphexVault.getMinPrice(_underlyingToken);
        uint256 feeBasisPoints = vaultUtils.getBuyUsdgFeeBasisPoints(
            _underlyingToken,
            usdgNeeded
        );
        uint256 afterFeeAmount = (_bltAmountNeeded *
            (morphexVault.BASIS_POINTS_DIVISOR() + feeBasisPoints)) /
            morphexVault.BASIS_POINTS_DIVISOR();

        uint256 startingTokenAmount = afterFeeAmount / tokenPrice;

        startingTokenAmount = morphexVault.adjustForDecimals(
            afterFeeAmount,
            morphexVault.usdg(),
            _underlyingToken
        );

        return startingTokenAmount;
    }

    function quoteAddLiquidityUnderlying(
        address underlyingToken,
        address token,
        uint amountUnderlyingDesired,
        uint amountTokenDesired
    )
        external
        view
        returns (
            uint amountUnderlying,
            uint amountWrappedBLT,
            uint amountToken,
            uint liquidity
        )
    {
        // create the pair if it doesn't exist yet
        address _pair = IPairFactory(factory).getPair(
            address(wBLT),
            token,
            false
        );
        (uint reserveA, uint reserveB) = (0, 0);
        uint _totalSupply = 0;

        // convert our amountUnderlyingDesired to amountWrappedBLTDesired
        uint256 amountWrappedBLTDesired = getMintAmountWrappedBLT(
            underlyingToken,
            amountUnderlyingDesired
        );

        if (_pair != address(0)) {
            _totalSupply = IERC20(_pair).totalSupply();
            (reserveA, reserveB) = getReserves(address(wBLT), token, false);
        }
        if (reserveA == 0 && reserveB == 0) {
            (amountWrappedBLT, amountToken) = (
                amountWrappedBLTDesired,
                amountTokenDesired
            );
            liquidity =
                Math.sqrt(amountWrappedBLT * amountToken) -
                MINIMUM_LIQUIDITY;
        } else {
            uint amountTokenOptimal = quoteLiquidity(
                amountWrappedBLTDesired,
                reserveA,
                reserveB
            );
            if (amountTokenOptimal <= amountTokenDesired) {
                (amountWrappedBLT, amountToken) = (
                    amountWrappedBLTDesired,
                    amountTokenOptimal
                );
                liquidity = Math.min(
                    (amountWrappedBLT * _totalSupply) / reserveA,
                    (amountToken * _totalSupply) / reserveB
                );
            } else {
                uint amountWrappedBLTOptimal = quoteLiquidity(
                    amountTokenDesired,
                    reserveB,
                    reserveA
                );
                (amountWrappedBLT, amountToken) = (
                    amountWrappedBLTOptimal,
                    amountTokenDesired
                );
                liquidity = Math.min(
                    (amountWrappedBLT * _totalSupply) / reserveA,
                    (amountToken * _totalSupply) / reserveB
                );
            }
        }
        // based on the amount of wBLT, calculate how much of our underlying token we need to zap in
        amountUnderlying = quoteMintAmountBLT(
            underlyingToken,
            amountWrappedBLT
        );
    }

    function quoteAddLiquidity(
        address tokenA,
        address tokenB,
        bool stable,
        uint amountADesired,
        uint amountBDesired
    ) external view returns (uint amountA, uint amountB, uint liquidity) {
        // create the pair if it doesn't exist yet
        address _pair = IPairFactory(factory).getPair(tokenA, tokenB, stable);
        (uint reserveA, uint reserveB) = (0, 0);
        uint _totalSupply = 0;
        if (_pair != address(0)) {
            _totalSupply = IERC20(_pair).totalSupply();
            (reserveA, reserveB) = getReserves(tokenA, tokenB, stable);
        }
        if (reserveA == 0 && reserveB == 0) {
            (amountA, amountB) = (amountADesired, amountBDesired);
            liquidity = Math.sqrt(amountA * amountB) - MINIMUM_LIQUIDITY;
        } else {
            uint amountBOptimal = quoteLiquidity(
                amountADesired,
                reserveA,
                reserveB
            );
            if (amountBOptimal <= amountBDesired) {
                (amountA, amountB) = (amountADesired, amountBOptimal);
                liquidity = Math.min(
                    (amountA * _totalSupply) / reserveA,
                    (amountB * _totalSupply) / reserveB
                );
            } else {
                uint amountAOptimal = quoteLiquidity(
                    amountBDesired,
                    reserveB,
                    reserveA
                );
                (amountA, amountB) = (amountAOptimal, amountBDesired);
                liquidity = Math.min(
                    (amountA * _totalSupply) / reserveA,
                    (amountB * _totalSupply) / reserveB
                );
            }
        }
    }

    function quoteRemoveLiquidity(
        address tokenA,
        address tokenB,
        bool stable,
        uint liquidity
    ) external view returns (uint amountA, uint amountB) {
        // create the pair if it doesn't exist yet
        address _pair = IPairFactory(factory).getPair(tokenA, tokenB, stable);

        if (_pair == address(0)) {
            return (0, 0);
        }

        (uint reserveA, uint reserveB) = getReserves(tokenA, tokenB, stable);
        uint _totalSupply = IERC20(_pair).totalSupply();

        amountA = (liquidity * reserveA) / _totalSupply; // using balances ensures pro-rata distribution
        amountB = (liquidity * reserveB) / _totalSupply; // using balances ensures pro-rata distribution
    }

    function quoteRemoveLiquidityUnderlying(
        address underlyingToken,
        address token,
        uint liquidity
    )
        external
        returns (uint amountUnderlying, uint amountWrappedBLT, uint amountToken)
    {
        // create the pair if it doesn't exist yet
        address _pair = IPairFactory(factory).getPair(
            address(wBLT),
            token,
            false
        );

        if (_pair == address(0)) {
            return (0, 0, 0);
        }

        (uint reserveA, uint reserveB) = getReserves(
            address(wBLT),
            token,
            false
        );
        uint _totalSupply = IERC20(_pair).totalSupply();

        amountWrappedBLT = (liquidity * reserveA) / _totalSupply; // using balances ensures pro-rata distribution
        amountToken = (liquidity * reserveB) / _totalSupply; // using balances ensures pro-rata distribution

        // simulate zapping out of wBLT to the selected underlying
        amountUnderlying = getRedeemAmountWrappedBLT(
            underlyingToken,
            amountWrappedBLT
        );
    }

    function _addLiquidity(
        address tokenA,
        address tokenB,
        bool stable,
        uint amountADesired,
        uint amountBDesired,
        uint amountAMin,
        uint amountBMin
    ) internal returns (uint amountA, uint amountB) {
        require(amountADesired >= amountAMin);
        require(amountBDesired >= amountBMin);

        address _pair = IPairFactory(factory).getPair(tokenA, tokenB, stable);
        if (_pair == address(0)) {
            _pair = IPairFactory(factory).createPair(tokenA, tokenB, stable);
        }

        // desired is the amount desired to be deposited for each token
        // optimal of one asset is the amount that is equal in value to our desired of the other asset
        // so, if our optimal is less than our min, we have an issue and pricing is likely off
        (uint reserveA, uint reserveB) = getReserves(tokenA, tokenB, stable);
        if (reserveA == 0 && reserveB == 0) {
            (amountA, amountB) = (amountADesired, amountBDesired);
        } else {
            uint amountBOptimal = quoteLiquidity(
                amountADesired,
                reserveA,
                reserveB
            );
            if (amountBOptimal <= amountBDesired) {
                require(
                    amountBOptimal >= amountBMin,
                    "Router: INSUFFICIENT_B_AMOUNT"
                );
                (amountA, amountB) = (amountADesired, amountBOptimal);
            } else {
                uint amountAOptimal = quoteLiquidity(
                    amountBDesired,
                    reserveB,
                    reserveA
                );
                assert(amountAOptimal <= amountADesired);
                require(
                    amountAOptimal >= amountAMin,
                    "Router: INSUFFICIENT_A_AMOUNT"
                );
                (amountA, amountB) = (amountAOptimal, amountBDesired);
            }
        }
    }

    function _safeTransferETH(address to, uint value) internal {
        (bool success, ) = to.call{value: value}(new bytes(0));
        require(success, "TransferHelper: ETH_TRANSFER_FAILED");
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
