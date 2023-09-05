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

    // original router vars
    address public immutable factory;
    IWETH public immutable weth;
    uint internal constant MINIMUM_LIQUIDITY = 10 ** 3;
    bytes32 immutable pairCodeHash;
    address[] public bltTokens;

    // standard Morphex contracts
    IBMX internal constant sBLT =
        IBMX(0x64755939a80BC89E1D2d0f93A312908D348bC8dE);

    VaultAPI internal constant wBLT =
        VaultAPI(0x4E74D4Db6c0726ccded4656d0BCE448876BB4C7A);

    IBMX internal constant rewardRouter =
        IBMX(0x49A97680938B4F1f73816d1B70C3Ab801FAd124B);

    IBMX internal constant bltManager =
        IBMX(0x9fAc7b75f367d5B35a6D6D0a09572eFcC3D406C5);

    IBMX internal constant vaultUtils =
        IBMX(0xec31c83C5689C66cb77DdB5378852F3707022039);

    IBMX internal constant morphexVault =
        IBMX(0xec8d8D4b215727f3476FF0ab41c406FA99b4272C);

    IBMX public oBMX;

    modifier ensure(uint deadline) {
        require(deadline >= block.timestamp, "Router: EXPIRED");
        _;
    }

    constructor(address _factory, address _weth) {
        factory = _factory;
        pairCodeHash = IPairFactory(_factory).pairCodeHash();
        weth = IWETH(_weth);

        // do approvals for wBLT
        sBLT.approve(address(wBLT), type(uint256).max);

        // update our allowances
        updateAllowances();
    }

    receive() external payable {
        assert(msg.sender == address(weth)); // only accept ETH via fallback from the WETH contract
    }

    /* ========== NEW/MODIFIED FUNCTIONS ========== */

    function setoBmxAddress(address _oBmxAddress) external onlyOwner {
        oBMX = IBMX(_oBmxAddress);
        wBLT.approve(address(oBMX), type(uint256).max);
    }

    function updateAllowances() public onlyOwner {
        address bltManager = 0x9fAc7b75f367d5B35a6D6D0a09572eFcC3D406C5;
        // first, set all of our allowances to zero
        for (uint i = 0; i < bltTokens.length; ++i) {
            IERC20 token = IERC20(bltTokens[i]);
            token.approve(bltManager, 0);
        }

        // clear out our saved array
        delete bltTokens;

        // add our new tokens
        uint256 tokensCount = morphexVault.whitelistedTokenCount();
        for (uint i = 0; i < tokensCount; ++i) {
            IERC20 token = IERC20(
                morphexVault.allWhitelistedTokens(tokensCount)
            );
            token.approve(bltManager, type(uint256).max);
            bltTokens.push(address(token));
        }
    }

    // performs chained getAmountOut calculations on any number of pairs
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
                    amounts[i + 1] = getRedeemAmountBLT(
                        routes[i].to,
                        amounts[i]
                    );
                    continue;
                }
            } else if (routes[i].to == address(wBLT)) {
                // check to make sure it's one of the tokens in BLT
                if (isBLTToken(routes[i].from)) {
                    amounts[i + 1] = getMintAmountBLT(
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

    // removed the deadline and stable params here so stack isn't too deep
    // this function is only used when a user wants to zap from underlying into wBLT via the UI to pair with another asset
    function addLiquidityWBLT(
        address underlyingToken,
        uint amountToZapIn,
        address tokenA,
        address tokenB,
        uint amountADesired,
        uint amountBDesired,
        uint amountAMin,
        uint amountBMin,
        address to
    ) external returns (uint amountA, uint amountB, uint liquidity) {
        // check to make sure one of the tokens is wBLT
        if (tokenA != address(wBLT) && tokenB != address(wBLT)) {
            revert("This function is only for wBLT");
        }

        // first, deposit the underlying to wBLT, deposit function checks that underlying is actually in the LP
        _safeTransferFrom(
            underlyingToken,
            msg.sender,
            address(this),
            amountToZapIn
        );
        uint256 wBltToLp = _depositToWrappedBLT(underlyingToken);

        if (tokenA == address(wBLT)) {
            amountADesired = wBltToLp;
        } else {
            amountBDesired = wBltToLp;
        }

        (amountA, amountB) = _addLiquidity(
            tokenA,
            tokenB,
            false, // stable LPs with wBLT would be kind dumb
            amountADesired,
            amountBDesired,
            amountAMin,
            amountBMin
        );
        address pair = pairFor(tokenA, tokenB, false);
        _safeTransferFrom(tokenA, msg.sender, pair, amountA);
        _safeTransferFrom(tokenB, msg.sender, pair, amountB);
        liquidity = IPair(pair).mint(to);
    }

    function exerciseLpWithUnderlying(
        address _tokenToUse,
        uint256 _amount,
        uint256 _oTokenAmount,
        uint256 _discount,
        uint256 _deadline
    ) public returns (uint256, uint256) {
        _safeTransferFrom(_tokenToUse, msg.sender, address(this), _amount);
        _safeTransferFrom(
            address(oBMX),
            msg.sender,
            address(this),
            _oTokenAmount
        );
        uint256 wBltToLp = _depositToWrappedBLT(_tokenToUse);
        return
            oBMX.exerciseLp(
                _oTokenAmount,
                wBltToLp,
                msg.sender,
                _discount,
                _deadline
            );
    }

    function getMintAmountBLT(
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
            morphexVault.BASIS_POINTS_DIVISOR() -
            feeBasisPoints) / morphexVault.BASIS_POINTS_DIVISOR();

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

    function getRedeemAmountBLT(
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
            morphexVault.BASIS_POINTS_DIVISOR() -
            feeBasisPoints) / morphexVault.BASIS_POINTS_DIVISOR();

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

        // withdraw from the vault first
        uint256 toWithdraw = wBLT.withdraw();

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
        tokens = wBLT.deposit(newMlp);
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

    // performs chained getAmountOut calculations on any number of pairs
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

    function addLiquidity(
        address tokenA,
        address tokenB,
        bool stable,
        uint amountADesired,
        uint amountBDesired,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    )
        external
        ensure(deadline)
        returns (uint amountA, uint amountB, uint liquidity)
    {
        (amountA, amountB) = _addLiquidity(
            tokenA,
            tokenB,
            stable,
            amountADesired,
            amountBDesired,
            amountAMin,
            amountBMin
        );
        address pair = pairFor(tokenA, tokenB, stable);
        _safeTransferFrom(tokenA, msg.sender, pair, amountA);
        _safeTransferFrom(tokenB, msg.sender, pair, amountB);
        liquidity = IPair(pair).mint(to);
    }

    // **** REMOVE LIQUIDITY ****
    function removeLiquidity(
        address tokenA,
        address tokenB,
        bool stable,
        uint liquidity,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) public ensure(deadline) returns (uint amountA, uint amountB) {
        address pair = pairFor(tokenA, tokenB, stable);
        require(IPair(pair).transferFrom(msg.sender, pair, liquidity)); // send liquidity to pair
        (uint amount0, uint amount1) = IPair(pair).burn(to);
        (address token0, ) = sortTokens(tokenA, tokenB);
        (amountA, amountB) = tokenA == token0
            ? (amount0, amount1)
            : (amount1, amount0);
        require(amountA >= amountAMin, "Router: INSUFFICIENT_A_AMOUNT");
        require(amountB >= amountBMin, "Router: INSUFFICIENT_B_AMOUNT");
    }

    function removeLiquidityWithPermit(
        address tokenA,
        address tokenB,
        bool stable,
        uint liquidity,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline,
        bool approveMax,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external returns (uint amountA, uint amountB) {
        address pair = pairFor(tokenA, tokenB, stable);
        {
            uint value = approveMax ? type(uint).max : liquidity;
            IPair(pair).permit(
                msg.sender,
                address(this),
                value,
                deadline,
                v,
                r,
                s
            );
        }

        (amountA, amountB) = removeLiquidity(
            tokenA,
            tokenB,
            stable,
            liquidity,
            amountAMin,
            amountBMin,
            to,
            deadline
        );
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
