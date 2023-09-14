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
    profit_slippage = 800  # in BPS
    swap_slippage = 30

    obvm.approve(bvm_exercise_helper, 2**256 - 1, {"from": obvm_whale})
    fee_before = weth.balanceOf("0x58761D6C6bF6c4bab96CaE125a2e5c8B1859b48a")

    # use our preset slippage and amount
    result = bvm_exercise_helper.quoteExerciseProfit(to_exercise, 0)
    print("Result", result.dict())
    real_slippage = (result["expectedProfit"] - result["realProfit"]) / result[
        "expectedProfit"
    ]
    print("Slippage:", "{:,.2f}%".format(real_slippage * 100))

    bvm_exercise_helper.exercise(
        to_exercise, profit_slippage, swap_slippage, {"from": obvm_whale}
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


def test_bmx_exercise_helper(obmx, bmx, bmx_exercise_helper, weth, router, usdc, w_blt):
    # exercise a small amount
    obmx_whale = accounts.at("0xeA00CFb98716B70760A6E8A5Ffdb8781Ef63fa5A", force=True)
    obmx_before = obmx.balanceOf(obmx_whale)
    weth_before = weth.balanceOf(obmx_whale)

    # control how much we exercise. larger size, more slippage
    to_exercise = 10e18
    profit_slippage = 400  # in BPS
    swap_slippage = 30

    obmx.approve(bmx_exercise_helper, 2**256 - 1, {"from": obmx_whale})
    fee_before = weth.balanceOf("0x58761D6C6bF6c4bab96CaE125a2e5c8B1859b48a")

    # use our preset slippage and amount
    result = bmx_exercise_helper.quoteExerciseProfit(to_exercise, 0)
    print("Result", result.dict())
    real_slippage = (result["expectedProfit"] - result["realProfit"]) / result[
        "expectedProfit"
    ]
    print("Slippage:", "{:,.2f}%".format(real_slippage * 100))

    # use our preset slippage and amount
    bmx_exercise_helper.exercise(
        to_exercise, profit_slippage, swap_slippage, {"from": obmx_whale}
    )

    assert obmx.balanceOf(obmx_whale) == obmx_before - to_exercise
    assert weth_before < weth.balanceOf(obmx_whale)
    profit = weth.balanceOf(obmx_whale) - weth_before
    fees = weth.balanceOf("0x58761D6C6bF6c4bab96CaE125a2e5c8B1859b48a") - fee_before

    assert bmx.balanceOf(bmx_exercise_helper) == 0
    assert weth.balanceOf(bmx_exercise_helper) == 0
    assert usdc.balanceOf(bmx_exercise_helper) == 0
    assert w_blt.balanceOf(bmx_exercise_helper) == 0
    assert obmx.balanceOf(bmx_exercise_helper) == 0

    print(
        "\n🥟 Dumped",
        "{:,.2f}".format(to_exercise / 1e18),
        "oBMX for",
        "{:,.5f}".format(profit / 1e18),
        "WETH 👻",
    )
    print("\n🤑 Took", "{:,.9f}".format(fees / 1e18), "WETH in fees\n")
