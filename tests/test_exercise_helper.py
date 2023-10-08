from brownie import config, Contract, ZERO_ADDRESS, chain, interface, accounts
import pytest


def test_bvm_exercise_helper(
    obvm,
    bvm_exercise_helper,
    weth,
    bvm,
    receive_underlying,
    obvm_whale,
    gauge,
):
    obvm_before = obvm.balanceOf(obvm_whale)
    weth_before = weth.balanceOf(obvm_whale)
    bvm_before = bvm.balanceOf(obvm_whale)

    # control how much we exercise. larger size, more slippage
    to_exercise = 1_000e18
    profit_slippage = 800  # in BPS
    swap_slippage = 50

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


def test_bvm_exercise_helper_lp(
    obvm,
    bvm_exercise_helper,
    weth,
    bvm,
    obvm_whale,
    gauge,
):
    # exercise a small amount
    obvm_before = obvm.balanceOf(obvm_whale)
    weth_before = weth.balanceOf(obvm_whale)
    bvm_before = bvm.balanceOf(obvm_whale)
    lp_before = gauge.balanceOf(obvm_whale)

    # control how much we exercise. larger size, more slippage
    to_exercise = 10_000e18
    profit_slippage = 800  # in BPS
    swap_slippage = 50
    percent_to_lp = 1255
    discount = 35

    # to_exercise: 500e18, percent_to_lp: 500 = , 701 = , 751 = , 755 = 0.04201%
    # to_exercise: 1_500e18, percent_to_lp: 500 = , 701 = , 751 = , 755 = 0.12592%
    # to_exercise: 3_000e18, percent_to_lp: 500 = , 701 = , 751 = , 755 = 0.25152%, 1200 = 0.23944%, 1250 = 0.23809%, 1255 = 0.23795% (no BVM, only dust WETH received since < 0.0001 WETH so no swap)
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
    obvm_whale,
    gauge,
    weth_whale,
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
