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
    slippage = 30  # in BPS

    obvm.approve(bvm_exercise_helper, 2**256 - 1, {"from": obvm_whale})
    fee_before = weth.balanceOf(bvm_exercise_helper.feeAddress())

    # use our preset slippage and amount
    bvm_exercise_helper.exercise(to_exercise, slippage, {"from": obvm_whale})

    assert obvm.balanceOf(obvm_whale) == obvm_before - to_exercise
    assert weth_before < weth.balanceOf(obvm_whale)
    profit = weth.balanceOf(obvm_whale) - weth_before
    fees = weth.balanceOf(bvm_exercise_helper.feeAddress()) - fee_before

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
    # whales deposit USDC to give us some flexibility, USDC-WETH pool on aerodrome
    token_whale = accounts.at("0xB4885Bc63399BF5518b994c1d0C153334Ee579D0", force=True)
    usdc.approve(router, 2**256 - 1, {"from": token_whale})

    usdc_to_wblt = [
        (usdc.address, w_blt.address, False),
    ]
    usdc_to_swap = 10_000e6

    router.swapExactTokensForTokens(
        usdc_to_swap, 0, usdc_to_wblt, token_whale, 2**256 - 1, {"from": token_whale}
    )

    # exercise a small amount
    obmx_whale = accounts.at("0x89955a99552F11487FFdc054a6875DF9446B2902", force=True)
    obmx_before = obmx.balanceOf(obmx_whale)
    weth_before = weth.balanceOf(obmx_whale)

    # control how much we exercise. larger size, more slippage
    to_exercise = 3e18
    slippage = 6000  # in BPS

    obmx.approve(bmx_exercise_helper, 2**256 - 1, {"from": obmx_whale})
    fee_before = weth.balanceOf(bmx_exercise_helper.feeAddress())

    # use our preset slippage and amount
    bmx_exercise_helper.exercise(to_exercise, slippage, {"from": obmx_whale})

    assert obmx.balanceOf(obmx_whale) == obmx_before - to_exercise
    assert weth_before < weth.balanceOf(obmx_whale)
    profit = weth.balanceOf(obmx_whale) - weth_before
    fees = weth.balanceOf(bmx_exercise_helper.feeAddress()) - fee_before

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
