import brownie
from brownie import config, Contract, ZERO_ADDRESS, chain, interface, accounts
import pytest

# the most effective way to test a situation where we have enough leftover WETH to swap is
#  to decrease the value on line 549 to 0
def test_bvm_exercise_helper(
    obvm,
    bvm_exercise_helper,
    weth,
    bvm,
    receive_underlying,
    obvm_whale,
    gauge,
    buy_underlying,
    weth_whale,
    router,
):
    obvm_before = obvm.balanceOf(obvm_whale)
    weth_before = weth.balanceOf(obvm_whale)
    bvm_before = bvm.balanceOf(obvm_whale)

    # test swapping in some WETH for BVM (this should give us positive slippage)
    if buy_underlying:
        weth.approve(router, 2**256 - 1, {"from": weth_whale})
        weth_to_bvm = [(weth.address, bvm.address, False)]
        weth_to_swap = 10e18
        router.swapExactTokensForTokens(
            weth_to_swap,
            0,
            weth_to_bvm,
            weth_whale.address,
            2**256 - 1,
            {"from": weth_whale},
        )

    # control how much we exercise. larger size, more slippage
    to_exercise = 1_000e18
    profit_slippage = 800  # in BPS
    swap_slippage = 100

    obvm.approve(bvm_exercise_helper, 2**256 - 1, {"from": obvm_whale})
    fee_before = weth.balanceOf(bvm_exercise_helper.feeAddress())

    if receive_underlying:
        result = bvm_exercise_helper.quoteExerciseToUnderlying(obvm, to_exercise, 0)
    else:
        result = bvm_exercise_helper.quoteExerciseProfit(obvm, to_exercise, 0)

    # use our preset slippage and amount
    print("Result w/ zero slippage", result.dict())
    real_slippage = (result["expectedProfit"] - result["realProfit"]) / result[
        "expectedProfit"
    ]
    print("Slippage (manually calculated):", "{:,.2f}%".format(real_slippage * 100))

    bvm_exercise_helper.exercise(
        obvm,
        to_exercise,
        receive_underlying,
        profit_slippage,
        swap_slippage,
        {"from": obvm_whale},
    )

    if receive_underlying:
        assert bvm_before < bvm.balanceOf(obvm_whale)
        profit = bvm.balanceOf(obvm_whale) - bvm_before
    else:
        assert weth_before < weth.balanceOf(obvm_whale)
        profit = weth.balanceOf(obvm_whale) - weth_before

    assert obvm.balanceOf(obvm_whale) == obvm_before - to_exercise
    fees = weth.balanceOf(bvm_exercise_helper.feeAddress()) - fee_before

    assert bvm.balanceOf(bvm_exercise_helper) == 0
    assert weth.balanceOf(bvm_exercise_helper) == 0
    assert obvm.balanceOf(bvm_exercise_helper) == 0
    assert gauge.balanceOf(bvm_exercise_helper) == 0

    weth_received = weth.balanceOf(obvm_whale) - weth_before
    bvm_received = bvm.balanceOf(obvm_whale) - bvm_before

    if receive_underlying:
        print(
            "\n🥟 Dumped",
            "{:,.2f}".format(to_exercise / 1e18),
            "oBVM for",
            "{:,.5f}".format(profit / 1e18),
            "BVM 👻",
        )
        print("Received", weth_received / 1e18, "WETH")
    else:
        print(
            "\n🥟 Dumped",
            "{:,.2f}".format(to_exercise / 1e18),
            "oBVM for",
            "{:,.5f}".format(profit / 1e18),
            "WETH 👻",
        )
        print("Received", bvm_received / 1e18, "BVM")
    print("\n🤑 Took", "{:,.9f}".format(fees / 1e18), "WETH in fees\n")

    # exercise again, so we hit both sides of our checkAllowances
    bvm_exercise_helper.exercise(
        obvm,
        to_exercise,
        receive_underlying,
        profit_slippage,
        swap_slippage,
        {"from": obvm_whale},
    )


# the most effective way to test a situation where we have "dust" WETH is to increase
#  the value on line 465 to 1e19
def test_bvm_exercise_helper_lp(
    obvm,
    bvm_exercise_helper,
    weth,
    bvm,
    obvm_whale,
    gauge,
    buy_underlying,
    weth_whale,
    router,
):
    # exercise a small amount
    obvm_before = obvm.balanceOf(obvm_whale)
    weth_before = weth.balanceOf(obvm_whale)
    bvm_before = bvm.balanceOf(obvm_whale)
    lp_before = gauge.balanceOf(obvm_whale)

    # test swapping in some WETH for BVM (this should give us positive slippage)
    if buy_underlying:
        weth.approve(router, 2**256 - 1, {"from": weth_whale})
        weth_to_bvm = [(weth.address, bvm.address, False)]
        weth_to_swap = 10e18
        router.swapExactTokensForTokens(
            weth_to_swap,
            0,
            weth_to_bvm,
            weth_whale.address,
            2**256 - 1,
            {"from": weth_whale},
        )

    # control how much we exercise. larger size, more slippage
    to_exercise = 1_000e18
    profit_slippage = 800  # in BPS
    swap_slippage = 100
    percent_to_lp = 1200
    discount = 35

    # use these for testing slippage between estimated and real LP amounts out
    # to_exercise: 500e18, percent_to_lp: 500 = , 701 = , 751 = , 755 = 0.04201%
    # to_exercise: 1_500e18, percent_to_lp: 500 = , 701 = , 751 = , 755 = 0.12592%
    # to_exercise: 3_000e18, percent_to_lp: 500 = , 701 = , 751 = , 755 = 0.25152%, 1200 = 0.23944%, 1250 = 0.23809%, 1255 = 0.23795%
    # to_exercise: 10_000e18, percent_to_lp: 1255 = 0.78879%

    obvm.approve(bvm_exercise_helper, 2**256 - 1, {"from": obvm_whale})
    fee_before = weth.balanceOf(bvm_exercise_helper.feeAddress())

    # first check exercising our LP
    output = bvm_exercise_helper.quoteExerciseLp(
        obvm, to_exercise, profit_slippage, percent_to_lp, discount
    )
    print("\nLP view output:", output.dict())
    print("Slippage:", output["profitSlippage"] / 1e18)
    print("Estimated LP Out:", output["lpAmountOut"] / 1e18)
    print("Estimated Extra underlying:", output["underlyingOut"] / 1e18)

    # use our preset slippage and amount
    bvm_exercise_helper.exerciseToLp(
        obvm,
        to_exercise,
        profit_slippage,
        swap_slippage,
        percent_to_lp,
        discount,
        {"from": obvm_whale},
    )

    assert obvm.balanceOf(obvm_whale) == obvm_before - to_exercise

    fees = weth.balanceOf(bvm_exercise_helper.feeAddress()) - fee_before

    assert bvm.balanceOf(bvm_exercise_helper) == 0
    assert weth.balanceOf(bvm_exercise_helper) == 0
    assert obvm.balanceOf(bvm_exercise_helper) == 0
    assert gauge.balanceOf(bvm_exercise_helper) == 0

    weth_received = weth.balanceOf(obvm_whale) - weth_before
    bvm_received = bvm.balanceOf(obvm_whale) - bvm_before
    lp_received = gauge.balanceOf(obvm_whale) - lp_before

    print(
        "LP % slippage:",
        "{:,.5f}%".format(
            100 * ((output["lpAmountOut"] - lp_received) / output["lpAmountOut"])
        ),
    )

    print("\nReceived", weth_received / 1e18, "WETH")  # $1600
    print("Received", bvm_received / 1e18, "BVM")  # $0.55
    print("LP Received:", lp_received / 1e18)  # $1.52941176471
    print("\n🤑 Took", "{:,.9f}".format(fees / 1e18), "WETH in fees\n")


def test_bvm_exercise_helper_lp_weird(
    obvm,
    bvm_exercise_helper,
    weth,
    bvm,
    tests_using_tenderly,
    weth_whale,
    obvm_whale,
    gauge,
):
    # we use tx.return_value here, and tenderly doesn't like that
    if tests_using_tenderly:
        return

    # exercise a small amount
    weth.transfer(obvm_whale, 10e18, {"from": weth_whale})
    obvm_before = obvm.balanceOf(obvm_whale)
    weth_before = weth.balanceOf(obvm_whale)
    bvm_before = bvm.balanceOf(obvm_whale)
    lp_before = gauge.balanceOf(obvm_whale)

    # control how much we exercise. larger size, more slippage
    to_exercise = 1_000e18
    profit_slippage = 800  # in BPS
    swap_slippage = 50
    percent_to_lp = 650
    discount = 35
    to_lp = int(1_000e18 * percent_to_lp / 10_000)

    obvm.approve(bvm_exercise_helper, 2**256 - 1, {"from": obvm_whale})

    # first check exercising our LP
    output = bvm_exercise_helper.quoteExerciseLp(
        obvm, to_exercise, profit_slippage, percent_to_lp, discount
    )
    print("\nLP view output:", output.dict())
    print("Slippage:", output["profitSlippage"] / 1e18)
    print("Estimated LP Out:", output["lpAmountOut"] / 1e18)
    print("Estimated Extra underlying:", output["underlyingOut"] / 1e18)

    output = obvm.getPaymentTokenAmountForExerciseLp(to_lp, discount)
    print(
        "Simulation:",
        output.dict(),
        output["paymentAmount"] + output["paymentAmountToAddLiquidity"],
    )

    # test swapping in some BVM for WETH
    dump_some_bvm = False
    if dump_some_bvm:
        bvm.approve(router, 2**256 - 1, {"from": obvm_whale})
        bvm_to_weth = [(bvm.address, weth.address, False)]
        bvm_to_swap = bvm.balanceOf(obvm_whale)
        router.swapExactTokensForTokens(
            bvm_to_swap,
            0,
            bvm_to_weth,
            obvm_whale.address,
            2**256 - 1,
            {"from": obvm_whale},
        )

    weth.approve(obvm, 2**256 - 1, {"from": obvm_whale})
    tx = obvm.exerciseLp(
        to_lp, 2**256 - 1, obvm_whale, discount, 2**256 - 1, {"from": obvm_whale}
    )
    print("Real thing:", tx.return_value)
    obvm_after = obvm.balanceOf(obvm_whale)
    assert obvm_before - obvm_after == to_lp


def test_bvm_exercise_helper_reverts(
    obvm, bvm_exercise_helper, weth, bvm, obvm_whale, gauge, screamsh, bvm_whale, router
):
    # control how much we exercise. larger size, more slippage
    to_exercise = 1_000e18
    profit_slippage = 800  # in BPS
    swap_slippage = 50
    discount = 35
    percent_to_lp = 10_001

    # check our reverts for exercising
    with brownie.reverts("Can't exercise zero"):
        bvm_exercise_helper.quoteExerciseProfit(obvm, 0, profit_slippage)

    with brownie.reverts("Slippage must be less than 10,000"):
        bvm_exercise_helper.quoteExerciseProfit(obvm, to_exercise, 10_001)

    with brownie.reverts("Can't exercise zero"):
        bvm_exercise_helper.quoteExerciseToUnderlying(obvm, 0, profit_slippage)

    with brownie.reverts("Slippage must be less than 10,000"):
        bvm_exercise_helper.quoteExerciseToUnderlying(obvm, to_exercise, 10_001)

    with brownie.reverts("Percent must be < 10,000"):
        bvm_exercise_helper.quoteExerciseLp(
            obvm, to_exercise, profit_slippage, percent_to_lp, discount
        )

    percent_to_lp = 2500
    with brownie.reverts("Need more WETH, decrease _percentToLp or _discount values"):
        bvm_exercise_helper.quoteExerciseLp(
            obvm, to_exercise, profit_slippage, percent_to_lp, discount
        )

    percent_to_lp = 600
    profit_slippage = 1
    obvm.approve(bvm_exercise_helper, 2**256 - 1, {"from": obvm_whale})
    with brownie.reverts("Profit slippage higher than allowed"):
        bvm_exercise_helper.exerciseToLp(
            obvm,
            to_exercise,
            profit_slippage,
            swap_slippage,
            percent_to_lp,
            discount,
            {"from": obvm_whale},
        )
    with brownie.reverts("Profit slippage higher than allowed"):
        bvm_exercise_helper.exercise(
            obvm,
            to_exercise,
            False,
            profit_slippage,
            swap_slippage,
            {"from": obvm_whale},
        )

    # receiveFlashLoan
    with brownie.reverts("Only balancer vault can call"):
        bvm_exercise_helper.receiveFlashLoan(
            [weth.address], [69e18], [0], "0x", {"from": obvm_whale}
        )

    balancer = accounts.at("0xBA12222222228d8Ba445958a75a0704d566BF2C8", force=True)
    with brownie.reverts("Flashloan not in progress"):
        bvm_exercise_helper.receiveFlashLoan(
            [weth.address], [69e18], [0], "0x", {"from": balancer}
        )

    # setFee
    bvm_exercise_helper.setFee(screamsh, 50, {"from": screamsh})
    with brownie.reverts("setFee: Fee max is 1%"):
        bvm_exercise_helper.setFee(screamsh, 101, {"from": screamsh})

    with brownie.reverts():
        bvm_exercise_helper.setFee(obvm_whale, 10, {"from": obvm_whale})

    # getAmountsIn
    with brownie.reverts("getAmountsIn: Path length must be >1"):
        bvm_exercise_helper.getAmountsIn(1e18, [weth.address], {"from": screamsh})

    with brownie.reverts("_getAmountIn: amountOut must be >0"):
        bvm_exercise_helper.getAmountsIn(
            0, [weth.address, bvm.address], {"from": screamsh}
        )

    # max out allowed slippage so we don't revert on that
    to_exercise = 1_000e18
    profit_slippage = 10_000  # in BPS
    swap_slippage = 10_000
    discount = 35

    # dump the price to make it unprofitable to exercise
    bvm.approve(router, 2**256 - 1, {"from": bvm_whale})
    bvm_to_weth = [(bvm.address, weth.address, False)]
    bvm_to_swap = 500_000e18
    router.swapExactTokensForTokens(
        bvm_to_swap,
        0,
        bvm_to_weth,
        bvm_whale.address,
        2**256 - 1,
        {"from": bvm_whale},
    )

    # check more reverts for exercising
    with brownie.reverts("Cost exceeds profit"):
        bvm_exercise_helper.exerciseToLp(
            obvm,
            to_exercise,
            profit_slippage,
            swap_slippage,
            percent_to_lp,
            discount,
            {"from": obvm_whale},
        )

    with brownie.reverts("Cost exceeds profit"):
        bvm_exercise_helper.exercise(
            obvm,
            to_exercise,
            False,
            profit_slippage,
            swap_slippage,
            {"from": obvm_whale},
        )

    with brownie.reverts("Cost exceeds profit"):
        bvm_exercise_helper.exercise(
            obvm,
            to_exercise,
            True,
            profit_slippage,
            swap_slippage,
            {"from": obvm_whale},
        )

    with brownie.reverts("Cost exceeds profit"):
        bvm_exercise_helper.quoteExerciseProfit(obvm, to_exercise, profit_slippage)

    with brownie.reverts("Cost exceeds profit"):
        bvm_exercise_helper.quoteExerciseToUnderlying(
            obvm, to_exercise, profit_slippage
        )

    with brownie.reverts("Cost exceeds profit"):
        bvm_exercise_helper.quoteExerciseLp(
            obvm, to_exercise, profit_slippage, percent_to_lp, discount
        )
