import brownie
from brownie import config, Contract, ZERO_ADDRESS, chain, interface, accounts
import pytest

# the most effective way to test a situation where we have enough leftover WFTM to swap is
#  to decrease the value on line 550 to 0
def test_fvm_exercise_helper(
    ofvm,
    fvm_exercise_helper,
    wftm,
    fvm,
    receive_underlying,
    ofvm_whale,
    gauge,
    buy_underlying,
    wftm_whale,
    router,
):
    ofvm_before = ofvm.balanceOf(ofvm_whale)
    wftm_before = wftm.balanceOf(ofvm_whale)
    fvm_before = fvm.balanceOf(ofvm_whale)

    # test swapping in some WFTM for FVM (this should give us positive slippage)
    if buy_underlying:
        wftm.approve(router, 2**256 - 1, {"from": wftm_whale})
        wftm_to_fvm = [(wftm.address, fvm.address, False)]
        wftm_to_swap = 100_000e18
        router.swapExactTokensForTokens(
            wftm_to_swap,
            0,
            wftm_to_fvm,
            wftm_whale.address,
            2**256 - 1,
            {"from": wftm_whale},
        )

    # control how much we exercise. larger size, more slippage
    to_exercise = 1_000e18
    profit_slippage = 800  # in BPS
    swap_slippage = 100

    ofvm.approve(fvm_exercise_helper, 2**256 - 1, {"from": ofvm_whale})
    fee_before = wftm.balanceOf(fvm_exercise_helper.feeAddress())

    if receive_underlying:
        result = fvm_exercise_helper.quoteExerciseToUnderlying(ofvm, to_exercise, 0)
    else:
        result = fvm_exercise_helper.quoteExerciseProfit(ofvm, to_exercise, 0)

    # use our preset slippage and amount
    print("Result w/ zero slippage", result.dict())
    real_slippage = (result["expectedProfit"] - result["realProfit"]) / result[
        "expectedProfit"
    ]
    print(
        "Slippage (manually calculated, negative means extra profit):",
        "{:,.2f}%".format(real_slippage * 100),
    )

    fvm_exercise_helper.exercise(
        ofvm,
        to_exercise,
        receive_underlying,
        profit_slippage,
        swap_slippage,
        {"from": ofvm_whale},
    )

    if receive_underlying:
        assert fvm_before < fvm.balanceOf(ofvm_whale)
        profit = fvm.balanceOf(ofvm_whale) - fvm_before
    else:
        assert wftm_before < wftm.balanceOf(ofvm_whale)
        profit = wftm.balanceOf(ofvm_whale) - wftm_before

    assert ofvm.balanceOf(ofvm_whale) == ofvm_before - to_exercise
    fees = wftm.balanceOf(fvm_exercise_helper.feeAddress()) - fee_before

    assert fvm.balanceOf(fvm_exercise_helper) == 0
    assert wftm.balanceOf(fvm_exercise_helper) == 0
    assert ofvm.balanceOf(fvm_exercise_helper) == 0
    assert gauge.balanceOf(fvm_exercise_helper) == 0

    wftm_received = wftm.balanceOf(ofvm_whale) - wftm_before
    fvm_received = fvm.balanceOf(ofvm_whale) - fvm_before

    if receive_underlying:
        print(
            "\n🥟 Dumped",
            "{:,.2f}".format(to_exercise / 1e18),
            "oFVM for",
            "{:,.5f}".format(profit / 1e18),
            "FVM 👻",
        )
        print("Received", wftm_received / 1e18, "WFTM")
    else:
        print(
            "\n🥟 Dumped",
            "{:,.2f}".format(to_exercise / 1e18),
            "oFVM for",
            "{:,.5f}".format(profit / 1e18),
            "WFTM 👻",
        )
        print("Received", fvm_received / 1e18, "FVM")
    print("\n🤑 Took", "{:,.9f}".format(fees / 1e18), "WFTM in fees\n")

    # exercise again, so we hit both sides of our checkAllowances
    fvm_exercise_helper.exercise(
        ofvm,
        to_exercise,
        receive_underlying,
        profit_slippage,
        swap_slippage,
        {"from": ofvm_whale},
    )


# the most effective way to test a situation where we have "dust" WFTM is to increase
#  the value on line 466 to 5e22
def test_fvm_exercise_helper_lp(
    ofvm,
    fvm_exercise_helper,
    wftm,
    fvm,
    ofvm_whale,
    gauge,
    buy_underlying,
    wftm_whale,
    router,
):
    # exercise a small amount
    ofvm_before = ofvm.balanceOf(ofvm_whale)
    wftm_before = wftm.balanceOf(ofvm_whale)
    fvm_before = fvm.balanceOf(ofvm_whale)
    lp_before = gauge.balanceOf(ofvm_whale)

    # test swapping in some WFTM for FVM (this should give us positive slippage)
    if buy_underlying:
        wftm.approve(router, 2**256 - 1, {"from": wftm_whale})
        wftm_to_fvm = [(wftm.address, fvm.address, False)]
        wftm_to_swap = 100_000e18
        router.swapExactTokensForTokens(
            wftm_to_swap,
            0,
            wftm_to_fvm,
            wftm_whale.address,
            2**256 - 1,
            {"from": wftm_whale},
        )

    # control how much we exercise. larger size, more slippage
    to_exercise = 10_000e18
    profit_slippage = 800  # in BPS
    swap_slippage = 100
    percent_to_lp = 1200
    discount = 35

    # use these for testing slippage between estimated and real LP amounts out
    # to_exercise: 500e18, percent_to_lp: 500 = , 701 = , 751 = , 755 = 0.04201%
    # to_exercise: 1_500e18, percent_to_lp: 500 = , 701 = , 751 = , 755 = 0.12592%
    # to_exercise: 3_000e18, percent_to_lp: 500 = , 701 = , 751 = , 755 = 0.25152%, 1200 = 0.23944%, 1250 = 0.23809%, 1255 = 0.23795%
    # to_exercise: 10_000e18, percent_to_lp: 1255 = 0.78879%

    ofvm.approve(fvm_exercise_helper, 2**256 - 1, {"from": ofvm_whale})
    fee_before = wftm.balanceOf(fvm_exercise_helper.feeAddress())

    # first check exercising our LP
    output = fvm_exercise_helper.quoteExerciseLp(
        ofvm, to_exercise, profit_slippage, percent_to_lp, discount
    )
    print("\nLP view output:", output.dict())
    print("Slippage:", output["profitSlippage"] / 1e18)
    print("Estimated LP Out:", output["lpAmountOut"] / 1e18)
    print("Estimated Extra underlying:", output["underlyingOut"] / 1e18)

    # use our preset slippage and amount
    fvm_exercise_helper.exerciseToLp(
        ofvm,
        to_exercise,
        profit_slippage,
        swap_slippage,
        percent_to_lp,
        discount,
        {"from": ofvm_whale},
    )

    assert ofvm.balanceOf(ofvm_whale) == ofvm_before - to_exercise

    fees = wftm.balanceOf(fvm_exercise_helper.feeAddress()) - fee_before

    assert fvm.balanceOf(fvm_exercise_helper) == 0
    assert wftm.balanceOf(fvm_exercise_helper) == 0
    assert ofvm.balanceOf(fvm_exercise_helper) == 0
    assert gauge.balanceOf(fvm_exercise_helper) == 0

    wftm_received = wftm.balanceOf(ofvm_whale) - wftm_before
    fvm_received = fvm.balanceOf(ofvm_whale) - fvm_before
    lp_received = gauge.balanceOf(ofvm_whale) - lp_before

    print(
        "LP % slippage:",
        "{:,.5f}%".format(
            100 * ((output["lpAmountOut"] - lp_received) / output["lpAmountOut"])
        ),
    )

    print("\nReceived", wftm_received / 1e18, "WFTM")  # $1600
    print("Received", fvm_received / 1e18, "FVM")  # $0.55
    print("LP Received:", lp_received / 1e18)  # $1.52941176471
    print("\n🤑 Took", "{:,.9f}".format(fees / 1e18), "WFTM in fees\n")


def test_fvm_exercise_helper_lp_weird(
    ofvm,
    fvm_exercise_helper,
    wftm,
    fvm,
    tests_using_tenderly,
    wftm_whale,
    ofvm_whale,
    gauge,
):
    # we use tx.return_value here, and tenderly doesn't like that
    if tests_using_tenderly:
        return

    # exercise a small amount
    wftm.transfer(ofvm_whale, 1_000e18, {"from": wftm_whale})
    ofvm_before = ofvm.balanceOf(ofvm_whale)
    wftm_before = wftm.balanceOf(ofvm_whale)
    fvm_before = fvm.balanceOf(ofvm_whale)
    lp_before = gauge.balanceOf(ofvm_whale)

    # control how much we exercise. larger size, more slippage
    to_exercise = 1_000e18
    profit_slippage = 800  # in BPS
    swap_slippage = 50
    percent_to_lp = 650
    discount = 35
    to_lp = int(1_000e18 * percent_to_lp / 10_000)

    ofvm.approve(fvm_exercise_helper, 2**256 - 1, {"from": ofvm_whale})

    # first check exercising our LP
    output = fvm_exercise_helper.quoteExerciseLp(
        ofvm, to_exercise, profit_slippage, percent_to_lp, discount
    )
    print("\nLP view output:", output.dict())
    print("Slippage:", output["profitSlippage"] / 1e18)
    print("Estimated LP Out:", output["lpAmountOut"] / 1e18)
    print("Estimated Extra underlying:", output["underlyingOut"] / 1e18)

    output = ofvm.getPaymentTokenAmountForExerciseLp(to_lp, discount)
    print(
        "Simulation:",
        output.dict(),
        output["paymentAmount"] + output["paymentAmountToAddLiquidity"],
    )

    # test swapping in some FVM for WFTM
    dump_some_fvm = False
    if dump_some_fvm:
        fvm.approve(router, 2**256 - 1, {"from": ofvm_whale})
        fvm_to_wftm = [(fvm.address, wftm.address, False)]
        fvm_to_swap = fvm.balanceOf(ofvm_whale)
        router.swapExactTokensForTokens(
            fvm_to_swap,
            0,
            fvm_to_wftm,
            ofvm_whale.address,
            2**256 - 1,
            {"from": ofvm_whale},
        )

    wftm.approve(ofvm, 2**256 - 1, {"from": ofvm_whale})
    tx = ofvm.exerciseLp(
        to_lp, 2**256 - 1, ofvm_whale, discount, 2**256 - 1, {"from": ofvm_whale}
    )
    print("Real thing:", tx.return_value)
    ofvm_after = ofvm.balanceOf(ofvm_whale)
    assert ofvm_before - ofvm_after == to_lp


def test_fvm_exercise_helper_reverts(
    ofvm, fvm_exercise_helper, wftm, fvm, ofvm_whale, gauge, screamsh, fvm_whale, router
):
    # control how much we exercise. larger size, more slippage
    to_exercise = 1_000e18
    profit_slippage = 800  # in BPS
    swap_slippage = 50
    discount = 35
    percent_to_lp = 10_001

    # check our reverts for exercising
    with brownie.reverts("Can't exercise zero"):
        fvm_exercise_helper.quoteExerciseProfit(ofvm, 0, profit_slippage)

    with brownie.reverts("Slippage must be less than 10,000"):
        fvm_exercise_helper.quoteExerciseProfit(ofvm, to_exercise, 10_001)

    with brownie.reverts("Can't exercise zero"):
        fvm_exercise_helper.quoteExerciseToUnderlying(ofvm, 0, profit_slippage)

    with brownie.reverts("Slippage must be less than 10,000"):
        fvm_exercise_helper.quoteExerciseToUnderlying(ofvm, to_exercise, 10_001)

    with brownie.reverts("Percent must be < 10,000"):
        fvm_exercise_helper.quoteExerciseLp(
            ofvm, to_exercise, profit_slippage, percent_to_lp, discount
        )

    percent_to_lp = 2500
    with brownie.reverts("Need more WFTM, decrease _percentToLp or _discount values"):
        fvm_exercise_helper.quoteExerciseLp(
            ofvm, to_exercise, profit_slippage, percent_to_lp, discount
        )

    percent_to_lp = 600
    profit_slippage = 1
    ofvm.approve(fvm_exercise_helper, 2**256 - 1, {"from": ofvm_whale})
    with brownie.reverts("Profit slippage higher than allowed"):
        fvm_exercise_helper.exerciseToLp(
            ofvm,
            to_exercise,
            profit_slippage,
            swap_slippage,
            percent_to_lp,
            discount,
            {"from": ofvm_whale},
        )
    with brownie.reverts("Profit slippage higher than allowed"):
        fvm_exercise_helper.exercise(
            ofvm,
            to_exercise,
            False,
            profit_slippage,
            swap_slippage,
            {"from": ofvm_whale},
        )

    # receiveFlashLoan
    with brownie.reverts("Only balancer vault can call"):
        fvm_exercise_helper.receiveFlashLoan(
            [wftm.address], [69e18], [0], "0x", {"from": ofvm_whale}
        )

    balancer = accounts.at("0x20dd72Ed959b6147912C2e529F0a0C651c33c9ce", force=True)
    with brownie.reverts("Flashloan not in progress"):
        fvm_exercise_helper.receiveFlashLoan(
            [wftm.address], [69e18], [0], "0x", {"from": balancer}
        )

    # setFee
    fvm_exercise_helper.setFee(screamsh, 50, {"from": screamsh})
    with brownie.reverts("setFee: Fee max is 1%"):
        fvm_exercise_helper.setFee(screamsh, 101, {"from": screamsh})

    with brownie.reverts():
        fvm_exercise_helper.setFee(ofvm_whale, 10, {"from": ofvm_whale})

    # getAmountsIn
    with brownie.reverts("getAmountsIn: Path length must be >1"):
        fvm_exercise_helper.getAmountsIn(1e18, [wftm.address], {"from": screamsh})

    with brownie.reverts("_getAmountIn: _amountOut must be >0"):
        fvm_exercise_helper.getAmountsIn(
            0, [wftm.address, fvm.address], {"from": screamsh}
        )

    # max out allowed slippage so we don't revert on that
    to_exercise = 10_000e18
    profit_slippage = 10_000  # in BPS
    swap_slippage = 10_000
    discount = 35

    # dump the price to make it unprofitable to exercise
    fvm.approve(router, 2**256 - 1, {"from": fvm_whale})
    fvm_to_wftm = [(fvm.address, wftm.address, False)]
    fvm_to_swap = 1_000_000e18
    router.swapExactTokensForTokens(
        fvm_to_swap,
        0,
        fvm_to_wftm,
        fvm_whale.address,
        2**256 - 1,
        {"from": fvm_whale},
    )

    # check more reverts for exercising
    with brownie.reverts("Cost exceeds profit"):
        fvm_exercise_helper.exerciseToLp(
            ofvm,
            to_exercise,
            profit_slippage,
            swap_slippage,
            percent_to_lp,
            discount,
            {"from": ofvm_whale},
        )

    with brownie.reverts("Cost exceeds profit"):
        fvm_exercise_helper.exercise(
            ofvm,
            to_exercise,
            False,
            profit_slippage,
            swap_slippage,
            {"from": ofvm_whale},
        )

    with brownie.reverts("Cost exceeds profit"):
        fvm_exercise_helper.exercise(
            ofvm,
            to_exercise,
            True,
            profit_slippage,
            swap_slippage,
            {"from": ofvm_whale},
        )

    with brownie.reverts("Cost exceeds profit"):
        fvm_exercise_helper.quoteExerciseProfit(ofvm, to_exercise, profit_slippage)

    with brownie.reverts("Cost exceeds profit"):
        fvm_exercise_helper.quoteExerciseToUnderlying(
            ofvm, to_exercise, profit_slippage
        )

    with brownie.reverts("Cost exceeds profit"):
        fvm_exercise_helper.quoteExerciseLp(
            ofvm, to_exercise, profit_slippage, percent_to_lp, discount
        )
