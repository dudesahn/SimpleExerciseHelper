// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.17;

import "./Interfaces.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";

contract DumpHelper is Ownable2Step {
    struct route {
        address from;
        address to;
        bool stable;
    }

    IBMX public constant oBMX =
        IBMX(0x3Ff7AB26F2dfD482C40bDaDfC0e88D01BFf79713);

    IERC20 public constant weth =
        IERC20(0x4200000000000000000000000000000000000006);

    IERC20 public constant bmx =
        IERC20(0x548f93779fBC992010C07467cBaf329DD5F059B7);

    IBalancer public constant balancerVault =
        IBalancer(0xBA12222222228d8Ba445958a75a0704d566BF2C8);

    bool public flashEntered;

    route[] public constant wBltoWeth = [
        [
            0x4E74D4Db6c0726ccded4656d0BCE448876BB4C7A,
            0x4200000000000000000000000000000000000006,
            false
        ]
    ];
    route[] public bmxToWeth = [
        [
            0x548f93779fBC992010C07467cBaf329DD5F059B7,
            0x4E74D4Db6c0726ccded4656d0BCE448876BB4C7A,
            false
        ],
        [
            0x4E74D4Db6c0726ccded4656d0BCE448876BB4C7A,
            0x4200000000000000000000000000000000000006,
            false
        ]
    ];

    // assumes a token is paired with WETH
    function dumpForWeth(uint256 _amount) external {
        if (_amount == 0) {
            revert("Can't exercise zero");
        }

        // transfer option token
        _safeTransferFrom(address(oBMX), address(this), _amount);
        uint256 optionPrice = oBMX.getDiscountedPrice(_amount);
        flashExercise(optionPrice);
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
        if (msg.sender != address(balancerVault)) revert NotPair();
        if (!flashEntered) revert InvalidFlash();

        uint256 optionPrice = abi.decode(userData, (uint256));
        uint256 optionBal = oBMX.balanceOf(address(this));
        exerciseAndSwap(optionBal, optionPrice);

        uint256 payback = amounts[0] + feeAmounts[0];
        weth.transfer(address(balancerVault), payback);

        // check our profit and send back to user
        uint256 profit = weth.balanceOf(address(this));
        weth.safeTransfer(user, profit);
        flashEntered = false;
    }

    function exerciseAndSwap(
        uint256 _optionBal,
        uint256 _optionPrice
    ) internal {
        oBMX.exercise(_optionBal, _optionPrice, address(this));
        uint256 bmxBalance = bmx.balanceOf(address(this));

        // use our wBLT router to easily go from BMX -> WETH
        bmxRouter.swapExactTokensForTokens(
            bmxBalance,
            0,
            bmxToWeth,
            address(this),
            block.timestamp
        );
    }
}
