from brownie import config, Contract, ZERO_ADDRESS, chain, interface, accounts
from utils import harvest_strategy
import pytest


def test_bvm_exercise_helper(
    obvm,
    bvm_exercise_helper,
    weth,
):
    obvm_whale = accounts.at("0x06b16991B53632C2362267579AE7C4863c72fDb8", force=True)
    obvm_before = obvm.balanceOf(obvm_whale)
    weth_before = weth.balanceOf(obvm_whale)

    obvm.approve(bvm_exercise_helper, 2**256 - 1, {"from": obvm_whale})
    fee_before = weth.balanceOf(bvm_exercise_helper.feeAddress())
    bvm_exercise_helper.exercise(obvm_before, {"from": obvm_whale})
    assert obvm.balanceOf(obvm_whale) == 0
    assert weth_before < weth.balanceOf(obvm_whale)
    profit = weth.balanceOf(obvm_whale) - weth_before
    fees = weth.balanceOf(bvm_exercise_helper.feeAddress()) - fee_before
    print(
        "\n🥟 Dumped",
        "{:,.2f}".format(obvm_before / 1e18),
        "oFVM for",
        "{:,.2f}".format(profit / 1e18),
        "WETH 👻\n",
    )
    print("\n🤑 Took", "{:,.5f}".format(fees / 1e18), "WETH in fees\n")


def test_bmx_exercise_helper(
    obmx,
    bmx_exercise_helper,
    weth,
):
    obmx_whale = accounts.at("", force=True)
    obvm_before = obvm.balanceOf(obvm_whale)
    weth_before = weth.balanceOf(obvm_whale)

    obvm.approve(bmx_exercise_helper, 2**256 - 1, {"from": obvm_whale})
    fee_before = weth.balanceOf(bmx_exercise_helper.feeAddress())
    bmx_exercise_helper.exercise(obvm_before, {"from": obvm_whale})
    assert obvm.balanceOf(obvm_whale) == 0
    assert weth_before < weth.balanceOf(obvm_whale)
    profit = weth.balanceOf(obvm_whale) - weth_before
    fees = weth.balanceOf(bmx_exercise_helper.feeAddress()) - fee_before
    print(
        "\n🥟 Dumped",
        "{:,.2f}".format(obvm_before / 1e18),
        "oFVM for",
        "{:,.2f}".format(profit / 1e18),
        "WETH 👻\n",
    )
    print("\n🤑 Took", "{:,.5f}".format(fees / 1e18), "WETH in fees\n")
