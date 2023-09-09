// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.17;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

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

contract DumpHelperBMX is Ownable2Step {
    IoToken public constant oBMX =
        IoToken(0x3Ff7AB26F2dfD482C40bDaDfC0e88D01BFf79713);

    IERC20 public constant weth =
        IERC20(0x4200000000000000000000000000000000000006);

    IERC20 public constant bmx =
        IERC20(0x548f93779fBC992010C07467cBaf329DD5F059B7);

    IBalancer public constant balancerVault =
        IBalancer(0xBA12222222228d8Ba445958a75a0704d566BF2C8);

    IRouter constant router =
        IRouter(0x82E98c956BAe12961e89d5107df78D3298aa151a); // this is our special wBLT-BMX router, v8

    bool public flashEntered;

    address internal constant feeAddress =
        0x87155E40F969FDAe7b73015dc2c1ce53003Ff70F;

    IRouter.route[] public wBltoWeth;
    IRouter.route[] public bmxToWeth;

    constructor(
        IRouter.route[] memory _wBltoWeth,
        IRouter.route[] memory _bmxToWeth
    ) {
        for (uint i; i < _wBltoWeth.length; ++i) {
            wBltoWeth.push(_wBltoWeth[i]);
        }

        for (uint i; i < _bmxToWeth.length; ++i) {
            bmxToWeth.push(_bmxToWeth[i]);
        }
    }

    /// @notice Dump our oBMX for WETH.
    function dumpForWeth(uint256 _amount) external {
        if (_amount == 0) {
            revert("Can't exercise zero");
        }

        // transfer option token
        _safeTransferFrom(address(oBMX), msg.sender, address(this), _amount);
        uint256 optionPrice = oBMX.getDiscountedPrice(_amount);
        flashExercise(optionPrice);

        // send profit back to user
        _safeTransfer(address(weth), msg.sender, weth.balanceOf(address(this)));
    }

    function flashExercise(uint256 _optionPrice) internal {
        flashEntered = true;
        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = _optionPrice;

        // need top convert this amount of wBLT to WETH
        _optionPrice = router.getAmountsOut(_optionPrice, wBltoWeth);

        bytes memory userData = abi.encode(_optionPrice);
        balancerVault.flashLoan(address(this), tokens, amounts, userData);
    }

    function receiveFlashLoan(
        address[] memory tokens,
        uint256[] memory amounts,
        uint256[] memory feeAmounts,
        bytes memory userData
    ) external {
        if (msg.sender != address(balancerVault)) revert("Not balancer");
        if (!flashEntered) revert("Flashloan not in progress");

        uint256 optionPrice = abi.decode(userData, (uint256));
        uint256 optionBal = oBMX.balanceOf(address(this));
        exerciseAndSwap(optionBal, optionPrice);

        uint256 payback = amounts[0] + feeAmounts[0];
        _safeTransfer(address(weth), address(balancerVault), payback);

        // check our profit and send back to user
        uint256 profit = weth.balanceOf(address(this));
        profit = takeFees(profit);
        flashEntered = false;
    }

    function takeFees(uint256 _profitAmount) internal {
        // send fees
        uint256 toSend = (_profitAmount * 25) / 10_000;
        _safeTransfer(address(weth), feeAddress, toSend);
    }

    function exerciseAndSwap(
        uint256 _optionBal,
        uint256 _optionPrice
    ) internal {
        oBMX.exercise(_optionBal, _optionPrice, address(this));
        uint256 bmxBalance = bmx.balanceOf(address(this));

        // use our wBLT router to easily go from BMX -> WETH
        router.swapExactTokensForTokens(
            bmxBalance,
            0,
            bmxToWeth,
            address(this),
            block.timestamp
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
