from brownie import config, Contract, ZERO_ADDRESS, chain, interface, accounts
from utils import harvest_strategy
import pytest


def test_bvm_exercise_helper(
    obvm,
    bvm_exercise_helper,
    weth,
    bvm,
):
    obvm_whale = accounts.at("0x06b16991B53632C2362267579AE7C4863c72fDb8", force=True)
    obvm_before = obvm.balanceOf(obvm_whale)
    weth_before = weth.balanceOf(obvm_whale)

    # control how much we exercise. larger size, more slippage
    to_exercise = 1_000e18
    profit_slippage = 2000  # in BPS
    swap_slippage = 50

    obvm.approve(bvm_exercise_helper, 2**256 - 1, {"from": obvm_whale})
    fee_before = weth.balanceOf("0x58761D6C6bF6c4bab96CaE125a2e5c8B1859b48a")

    # use our preset slippage and amount
    result = bvm_exercise_helper.quoteExerciseProfit(obvm, to_exercise, 0)
    print("Result w/ zero slippage", result.dict())
    real_slippage = (result["expectedProfit"] - result["realProfit"]) / result[
        "expectedProfit"
    ]
    print("Slippage (manually calculated):", "{:,.2f}%".format(real_slippage * 100))

    bvm_exercise_helper.exercise(
        obvm, to_exercise, profit_slippage, swap_slippage, {"from": obvm_whale}
    )

    assert obvm.balanceOf(obvm_whale) == obvm_before - to_exercise
    assert weth_before < weth.balanceOf(obvm_whale)
    profit = weth.balanceOf(obvm_whale) - weth_before
    fees = weth.balanceOf("0x58761D6C6bF6c4bab96CaE125a2e5c8B1859b48a") - fee_before

    assert bvm.balanceOf(bvm_exercise_helper) == 0
    assert weth.balanceOf(bvm_exercise_helper) == 0
    assert obvm.balanceOf(bvm_exercise_helper) == 0

    print(
        "\n🥟 Dumped",
        "{:,.2f}".format(to_exercise / 1e18),
        "oBVM for",
        "{:,.5f}".format(profit / 1e18),
        "WETH 👻",
    )
    print("\n🤑 Took", "{:,.9f}".format(fees / 1e18), "WETH in fees\n")


def test_bmx_exercise_helper(
    obmx, bmx, bmx_exercise_helper, weth, router, usdc, w_blt, receive_underlying
):
    # exercise a small amount
    obmx_whale = accounts.at("0xeA00CFb98716B70760A6E8A5Ffdb8781Ef63fa5A", force=True)
    obmx_before = obmx.balanceOf(obmx_whale)
    weth_before = weth.balanceOf(obmx_whale)
    bmx_before = bmx.balanceOf(obmx_whale)
    wblt_before = w_blt.balanceOf(obmx_whale)

    # control how much we exercise. larger size, more slippage
    to_exercise = 100e18
    profit_slippage = 2000  # in BPS
    swap_slippage = 50

    obmx.approve(bmx_exercise_helper, 2**256 - 1, {"from": obmx_whale})
    fee_before = weth.balanceOf("0x58761D6C6bF6c4bab96CaE125a2e5c8B1859b48a")

    # use our preset slippage and amount
    if receive_underlying:
        result = bmx_exercise_helper.quoteExerciseToUnderlying(obmx, to_exercise, 0)
    else:
        result = bmx_exercise_helper.quoteExerciseProfit(obmx, to_exercise, 0)
    print("Result w/ zero slippage", result.dict())
    real_slippage = (result["expectedProfit"] - result["realProfit"]) / result[
        "expectedProfit"
    ]
    print("Slippage (manually calculated):", "{:,.2f}%".format(real_slippage * 100))

    # use our preset slippage and amount
    bmx_exercise_helper.exercise(
        obmx,
        to_exercise,
        receive_underlying,
        profit_slippage,
        swap_slippage,
        {"from": obmx_whale},
    )

    if receive_underlying:
        assert bmx_before < bmx.balanceOf(obmx_whale)
        profit = bmx.balanceOf(obmx_whale) - bmx_before
    else:
        assert weth_before < weth.balanceOf(obmx_whale)
        profit = weth.balanceOf(obmx_whale) - weth_before

    assert obmx.balanceOf(obmx_whale) == obmx_before - to_exercise

    fees = weth.balanceOf("0x58761D6C6bF6c4bab96CaE125a2e5c8B1859b48a") - fee_before

    assert bmx.balanceOf(bmx_exercise_helper) == 0
    assert weth.balanceOf(bmx_exercise_helper) == 0
    assert usdc.balanceOf(bmx_exercise_helper) == 0
    assert w_blt.balanceOf(bmx_exercise_helper) == 0
    assert obmx.balanceOf(bmx_exercise_helper) == 0

    weth_received = weth.balanceOf(obmx_whale) - weth_before
    wblt_received = w_blt.balanceOf(obmx_whale) - wblt_before
    bmx_received = bmx.balanceOf(obmx_whale) - bmx_before

    if receive_underlying:
        print(
            "\n🥟 Dumped",
            "{:,.2f}".format(to_exercise / 1e18),
            "oBMX for",
            "{:,.5f}".format(profit / 1e18),
            "BMX 👻",
        )
        print("Received", wblt_received / 1e18, "wBLT")
        print("Received", weth_received / 1e18, "WETH")
    else:
        print(
            "\n🥟 Dumped",
            "{:,.2f}".format(to_exercise / 1e18),
            "oBMX for",
            "{:,.5f}".format(profit / 1e18),
            "WETH 👻",
        )
        print("Received", wblt_received / 1e18, "wBLT")
        print("Received", bmx_received / 1e18, "BMX")
    print("\n🤑 Took", "{:,.9f}".format(fees / 1e18), "WETH in fees\n")


def test_bmx_exercise_helper_lp(
    obmx, bmx, bmx_exercise_helper, weth, router, usdc, w_blt
):
    # exercise a small amount
    obmx_whale = accounts.at("0xeA00CFb98716B70760A6E8A5Ffdb8781Ef63fa5A", force=True)
    obmx_before = obmx.balanceOf(obmx_whale)
    weth_before = weth.balanceOf(obmx_whale)
    bmx_before = bmx.balanceOf(obmx_whale)
    wblt_before = w_blt.balanceOf(obmx_whale)

    # control how much we exercise. larger size, more slippage
    to_exercise = 100e18
    profit_slippage = 4000  # in BPS
    swap_slippage = 50
    percent_to_lp = 650
    discount = 35

    obmx.approve(bmx_exercise_helper, 2**256 - 1, {"from": obmx_whale})
    fee_before = weth.balanceOf("0x58761D6C6bF6c4bab96CaE125a2e5c8B1859b48a")
    gauge = Contract("0x1F7B5E65c09dF12742255BB8Fe26958f4B52F9bb")

    # first check exercising our LP
    output = bmx_exercise_helper.quoteExerciseLp(
        obmx, to_exercise, profit_slippage, percent_to_lp, discount
    )
    print("\nLP view output:", output.dict())
    print("Slippage:", output["profitSlippage"] / 1e18)

    # use our preset slippage and amount
    bmx_exercise_helper.exerciseToLp(
        obmx,
        to_exercise,
        profit_slippage,
        swap_slippage,
        percent_to_lp,
        discount,
        {"from": obmx_whale},
    )

    assert obmx.balanceOf(obmx_whale) == obmx_before - to_exercise

    fees = weth.balanceOf("0x58761D6C6bF6c4bab96CaE125a2e5c8B1859b48a") - fee_before

    assert bmx.balanceOf(bmx_exercise_helper) == 0
    assert weth.balanceOf(bmx_exercise_helper) == 0
    assert usdc.balanceOf(bmx_exercise_helper) == 0
    assert w_blt.balanceOf(bmx_exercise_helper) == 0
    assert obmx.balanceOf(bmx_exercise_helper) == 0

    weth_received = weth.balanceOf(obmx_whale) - weth_before
    wblt_received = w_blt.balanceOf(obmx_whale) - wblt_before
    bmx_received = bmx.balanceOf(obmx_whale) - bmx_before

    print("Received", weth_received / 1e18, "WETH")  # $1600
    print("Received", wblt_received / 1e18, "wBLT")  # $1.03
    print("Received", bmx_received / 1e18, "BMX")  # $0.55
    print("LP Balance:", gauge.balanceOf(obmx_whale) / 1e18)  # $1.52941176471
    print("\n🤑 Took", "{:,.9f}".format(fees / 1e18), "WETH in fees\n")
