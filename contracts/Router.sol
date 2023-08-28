// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.15;

interface IERC20 {
    function totalSupply() external view returns (uint256);

    function transfer(address recipient, uint amount) external returns (bool);

    function decimals() external view returns (uint8);

    function symbol() external view returns (string memory);

    function balanceOf(address) external view returns (uint);

    function transferFrom(
        address sender,
        address recipient,
        uint amount
    ) external returns (bool);

    function allowance(
        address owner,
        address spender
    ) external view returns (uint);

    function approve(address spender, uint value) external returns (bool);

    event Transfer(address indexed from, address indexed to, uint value);
    event Approval(address indexed owner, address indexed spender, uint value);
}

interface IPair {
    function metadata()
        external
        view
        returns (
            uint dec0,
            uint dec1,
            uint r0,
            uint r1,
            bool st,
            address t0,
            address t1
        );

    function tokens() external returns (address, address);

    function token0() external returns (address);

    function token1() external returns (address);

    function externalBribe() external returns (address);

    function transferFrom(
        address src,
        address dst,
        uint amount
    ) external returns (bool);

    function permit(
        address owner,
        address spender,
        uint value,
        uint deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;

    function swap(
        uint amount0Out,
        uint amount1Out,
        address to,
        bytes calldata data
    ) external;

    function burn(address to) external returns (uint amount0, uint amount1);

    function mint(address to) external returns (uint liquidity);

    function getReserves()
        external
        view
        returns (uint _reserve0, uint _reserve1, uint _blockTimestampLast);

    function getAmountOut(uint, address) external view returns (uint);

    function setHasGauge(bool value) external;

    function setExternalBribe(address _externalBribe) external;

    function hasGauge() external view returns (bool);

    function stable() external view returns (bool);

    function prices(
        address tokenIn,
        uint amountIn,
        uint points
    ) external view returns (uint[] memory);
}

interface IPairFactory {
    function allPairsLength() external view returns (uint);

    function isPair(address pair) external view returns (bool);

    function isPaused() external view returns (bool);

    function pairCodeHash() external pure returns (bytes32);

    function getFee(address pair) external view returns (uint256);

    function getPair(
        address tokenA,
        address token,
        bool stable
    ) external view returns (address);

    function getInitializable() external view returns (address, address, bool);

    function createPair(
        address tokenA,
        address tokenB,
        bool stable
    ) external returns (address pair);

    function voter() external view returns (address);

    function tank() external view returns (address);
}

interface IRouter {
    function pairFor(
        address tokenA,
        address tokenB,
        bool stable
    ) external view returns (address pair);

    function swapExactTokensForTokensSimple(
        uint amountIn,
        uint amountOutMin,
        address tokenFrom,
        address tokenTo,
        bool stable,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);

    function getAmountOut(
        uint amountIn,
        address tokenIn,
        address tokenOut,
        bool stable
    ) external view returns (uint amount);

    function getReserves(
        address tokenA,
        address tokenB,
        bool stable
    ) external view returns (uint, uint);

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
    ) external returns (uint, uint, uint);
}

interface IWETH is IERC20 {
    function deposit() external payable;

    function transfer(address to, uint256 value) external returns (bool);

    function withdraw(uint256) external;
}

interface IVault is IERC20 {
    function deposit(uint256) external returns (uint256);

    function withdraw() external returns (uint256);
}

interface IBMX is IERC20 {
    function unstakeAndRedeemGlp(
        address,
        uint256,
        uint256,
        address
    ) external returns (uint256);

    function mintAndStakeGlp(
        address,
        uint256,
        uint256,
        uint256
    ) external returns (uint256);
}

contract Router is IRouter {
    struct route {
        address from;
        address to;
        bool stable;
    }

    address public immutable factory;
    IWETH public immutable weth;
    uint internal constant MINIMUM_LIQUIDITY = 10 ** 3;
    bytes32 immutable pairCodeHash;
    IVault internal constant wblt =
        IVault(0x4E74D4Db6c0726ccded4656d0BCE448876BB4C7A);
    IERC20 internal constant usdc =
        IERC20(0xd9aAEc86B65D86f6A7B5B1b0c42FFA531710b6CA);
    IERC20 internal constant wbtc =
        IERC20(0x1a35EE4640b0A3B87705B0A4B45D227Ba60Ca2ad);
    IBMX internal constant rewardRouter =
        IBMX(0x49A97680938B4F1f73816d1B70C3Ab801FAd124B);
    address internal constant bmx = 0x548f93779fBC992010C07467cBaf329DD5F059B7;
    IERC20 internal constant sBlp =
        IERC20(0x64755939a80BC89E1D2d0f93A312908D348bC8dE);

    modifier ensure(uint deadline) {
        require(deadline >= block.timestamp, "Router: EXPIRED");
        _;
    }

    // approvals -> GLP manager to spend all constituent tokens

    constructor(address _factory, address _weth) {
        factory = _factory;
        pairCodeHash = IPairFactory(_factory).pairCodeHash();
        weth = IWETH(_weth);

        // do approvals for wBLT
        sBlp.approve(address(wblt), type(uint256).max);
        address blpManager = 0x9fAc7b75f367d5B35a6D6D0a09572eFcC3D406C5;
        weth.approve(blpManager, type(uint256).max);
        wbtc.approve(blpManager, type(uint256).max);
        usdc.approve(blpManager, type(uint256).max);
    }

    receive() external payable {
        assert(msg.sender == address(weth)); // only accept ETH via fallback from the WETH contract
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
            if (routes[i].from == address(wblt)) {
                // check here first if to != BMX, if it's BMX we can just swap directly
                if (routes[i].to != bmx) {
                    // check to make sure it's one of the tokens in BLT, if not revert
                    if (!isBlpToken(routes[i].to)) {
                        revert("token not in BLP");
                    } else {
                        uint256 received = _bltSimulateWithdrawal(routes[i].to);
                        if (i < (routes.length - 1)) {
                            continue;
                        } else {
                            // return the amount we end up with
                            return;
                        }
                    }
                }
            } else if (routes[i].to == address(wblt)) {
                if (routes[i].from != bmx) {
                    // check to make sure it's one of the tokens in BLT, if not revert
                    if (!isBlpToken(routes[i].from)) {
                        revert("token not in BLP");
                    } else {
                        uint256 received = _bltSimulateDeposit(routes[i].from);
                        if (i < (routes.length - 1)) {
                            continue;
                        } else {
                            // return the amount we end up with
                            return;
                        }
                    }
                }
            }
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

    function isPair(address pair) external view returns (bool) {
        return IPairFactory(factory).isPair(pair);
    }

    // **** SWAP ****
    // requires the initial amount to have already been sent to the first pair
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
            address to = i < routes.length - 1
                ? pairFor(
                    routes[i + 1].from,
                    routes[i + 1].to,
                    routes[i + 1].stable
                )
                : _to;

            // check if we need to convert to or from wBLT
            if (routes[i].from == address(wblt)) {
                // check here first if to != BMX, if it's BMX we can just swap directly
                if (routes[i].to != bmx) {
                    // check to make sure it's one of the tokens in BLT, if not revert
                    if (!isBlpToken(routes[i].to)) {
                        revert("token not in BLP");
                    } else {
                        uint256 received = _withdrawFromWrappedBLT(
                            routes[i].to
                        );
                        // if this is the last token, send to our _to address
                        if (i < (routes.length - 1)) {
                            continue;
                        } else {
                            _safeTransfer(routes[i].to, _to, received);
                            return;
                        }
                    }
                }
            } else if (routes[i].to == address(wblt)) {
                if (routes[i].from != bmx) {
                    // check to make sure it's one of the tokens in BLT, if not revert
                    if (!isBlpToken(routes[i].from)) {
                        revert("token not in BLP");
                    } else {
                        uint256 received = _depositToWrappedBLT(routes[i].from);
                        // if this is the last token, send to our _to address
                        if (i < (routes.length - 1)) {
                            continue;
                        } else {
                            _safeTransfer(address(wblt), _to, received);
                            return;
                        }
                    }
                }
            }
            // for this pair, we can just do a normal swap
            IPair(pairFor(routes[i].from, routes[i].to, routes[i].stable)).swap(
                    amount0Out,
                    amount1Out,
                    to,
                    new bytes(0)
                );
        }
    }

    function _withdrawFromWrappedBLT(
        address _targetToken
    ) internal returns (uint256) {
        // withdraw from the vault first
        uint256 toWithdraw = wblt.withdraw();

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
        // deposit to BLP and then the vault
        IERC20 token = IERC20(_fromToken);
        uint256 newMlp = rewardRouter.mintAndStakeGlp(
            address(_fromToken),
            token.balanceOf(address(this)),
            0,
            0
        );
        tokens = wblt.deposit(newMlp);
    }

    function isBlpToken(address _tokenToCheck) internal view returns (bool) {
        // check if a given token is in BLP
        if (address(usdc) == _tokenToCheck) {
            return true;
        } else if (address(weth) == _tokenToCheck) {
            return true;
        } else if (address(usdc) == _tokenToCheck) {
            return true;
        } else {
            return false;
        }
    }

    function swapExactTokensForTokensSimple(
        uint amountIn,
        uint amountOutMin,
        address tokenFrom,
        address tokenTo,
        bool stable,
        address to,
        uint deadline
    ) external ensure(deadline) returns (uint[] memory amounts) {
        route[] memory routes = new route[](1);
        routes[0].from = tokenFrom;
        routes[0].to = tokenTo;
        routes[0].stable = stable;
        amounts = getAmountsOut(amountIn, routes);
        require(
            amounts[amounts.length - 1] >= amountOutMin,
            "Router: INSUFFICIENT_OUTPUT_AMOUNT"
        );
        _safeTransferFrom(
            routes[0].from,
            msg.sender,
            pairFor(routes[0].from, routes[0].to, routes[0].stable),
            amounts[0]
        );
        _swap(amounts, routes, to);
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
        _safeTransferFrom(
            routes[0].from,
            msg.sender,
            pairFor(routes[0].from, routes[0].to, routes[0].stable),
            amounts[0]
        );
        _swap(amounts, routes, to);
    }

    function swapExactETHForTokens(
        uint amountOutMin,
        route[] calldata routes,
        address to,
        uint deadline
    ) external payable ensure(deadline) returns (uint[] memory amounts) {
        require(routes[0].from == address(weth), "Router: INVALID_PATH");
        amounts = getAmountsOut(msg.value, routes);
        require(
            amounts[amounts.length - 1] >= amountOutMin,
            "Router: INSUFFICIENT_OUTPUT_AMOUNT"
        );
        weth.deposit{value: amounts[0]}();
        assert(
            weth.transfer(
                pairFor(routes[0].from, routes[0].to, routes[0].stable),
                amounts[0]
            )
        );
        _swap(amounts, routes, to);
    }

    function swapExactTokensForETH(
        uint amountIn,
        uint amountOutMin,
        route[] calldata routes,
        address to,
        uint deadline
    ) external ensure(deadline) returns (uint[] memory amounts) {
        require(
            routes[routes.length - 1].to == address(weth),
            "Router: INVALID_PATH"
        );
        amounts = getAmountsOut(amountIn, routes);
        require(
            amounts[amounts.length - 1] >= amountOutMin,
            "Router: INSUFFICIENT_OUTPUT_AMOUNT"
        );
        _safeTransferFrom(
            routes[0].from,
            msg.sender,
            pairFor(routes[0].from, routes[0].to, routes[0].stable),
            amounts[0]
        );
        _swap(amounts, routes, address(this));
        weth.withdraw(amounts[amounts.length - 1]);
        _safeTransferETH(to, amounts[amounts.length - 1]);
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
