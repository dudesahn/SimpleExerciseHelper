from brownie import chain, Contract, interface, accounts
import pytest


def test_basic_swaps(
    bmx,
    screamsh,
    w_blt,
    router,
    weth,
    factory,
    usdc,
):

    # test views
    weth_to_mint = 1e15
    to_mint = router.getMintAmountBLT(weth, weth_to_mint)
    print("Mint wBLT with 0.001 ETH", to_mint / 1e18)

    weth_to_swap = 1e15
    weth_to_bmx = [
        (weth.address, w_blt.address, False),
        (w_blt.address, bmx.address, False),
    ]
    amounts = router.getAmountsOut(weth_to_swap, weth_to_bmx)
    print("Get amounts out for 0.001 ETH:", amounts)

    # swap for some BMX
    weth.approve(router, 2**256 - 1, {"from": screamsh})
    before = bmx.balanceOf(screamsh)
    router.swapExactTokensForTokens(
        weth_to_swap, 0, weth_to_bmx, screamsh, 2**256 - 1, {"from": screamsh}
    )
    assert bmx.balanceOf(screamsh) > before
    assert bmx.balanceOf(router) == 0
    assert weth.balanceOf(router) == 0
    assert usdc.balanceOf(router) == 0
    assert w_blt.balanceOf(router) == 0
    print("✅  Swapped to BMX")

    # approve our BMX, swap for USDC
    bmx.approve(router, 2**256 - 1, {"from": screamsh})
    bmx_to_usdc = [
        (bmx.address, w_blt.address, False),
        (w_blt.address, usdc.address, False),
    ]
    bmx_to_swap = bmx.balanceOf(screamsh)
    before = usdc.balanceOf(screamsh)
    router.swapExactTokensForTokens(
        bmx_to_swap, 0, bmx_to_usdc, screamsh.address, 2**256 - 1, {"from": screamsh}
    )
    assert usdc.balanceOf(screamsh) > before
    assert bmx.balanceOf(router) == 0
    assert weth.balanceOf(router) == 0
    assert usdc.balanceOf(router) == 0
    assert w_blt.balanceOf(router) == 0
    print("✅  Swapped back from BMX to USDC")

    # swap to wBLT
    weth_to_swap = 1e14
    weth_to_wblt = [(weth.address, w_blt.address, False)]
    before = w_blt.balanceOf(screamsh)
    router.swapExactTokensForTokens(
        weth_to_swap, 0, weth_to_wblt, screamsh, 2**256 - 1, {"from": screamsh}
    )
    assert w_blt.balanceOf(screamsh) > before
    assert bmx.balanceOf(router) == 0
    assert weth.balanceOf(router) == 0
    assert usdc.balanceOf(router) == 0
    assert w_blt.balanceOf(router) == 0
    print("✅  Swapped from WETH to wBLT")

    # swap wBLT to WETH
    wblt_to_swap = w_blt.balanceOf(screamsh)
    w_blt.approve(router, 2**256 - 1, {"from": screamsh})
    back_to_weth = [(w_blt.address, weth.address, False)]
    before = weth.balanceOf(screamsh)
    router.swapExactTokensForTokens(
        wblt_to_swap, 0, back_to_weth, screamsh, 2**256 - 1, {"from": screamsh}
    )
    assert weth.balanceOf(screamsh) > before
    assert bmx.balanceOf(router) == 0
    assert weth.balanceOf(router) == 0
    assert usdc.balanceOf(router) == 0
    assert w_blt.balanceOf(router) == 0
    print("✅  Swapped from wBLT back to WETH")


def test_eth_swaps(
    bmx,
    screamsh,
    w_blt,
    router,
    weth,
    factory,
    usdc,
):
    # ETH whale sends some to screamsh
    eth_whale = accounts.at("0x224D8Fd7aB6AD4c6eb4611Ce56EF35Dec2277F03", force=True)
    eth_whale.transfer(screamsh, 5e18)
    assert screamsh.balance() > 1e18

    # swap ETH to wBLT
    weth_to_swap = 1e18
    weth_to_wblt = [(weth.address, w_blt.address, False)]
    before = w_blt.balanceOf(screamsh)
    before_eth = screamsh.balance()
    router.swapExactETHForTokens(
        weth_to_swap,
        0,
        weth_to_wblt,
        screamsh,
        2**256 - 1,
        {"from": screamsh, "value": 1e18},
    )
    assert screamsh.balance() < before_eth
    assert w_blt.balanceOf(screamsh) > before
    assert bmx.balanceOf(router) == 0
    assert weth.balanceOf(router) == 0
    assert usdc.balanceOf(router) == 0
    assert w_blt.balanceOf(router) == 0
    print("✅  Swapped from ether to wBLT")

    # swap wBLT to ETH
    wblt_to_swap = w_blt.balanceOf(screamsh)
    w_blt.approve(router, 2**256 - 1, {"from": screamsh})
    back_to_weth = [(w_blt.address, weth.address, False)]
    before_eth = screamsh.balance()
    router.swapExactTokensForETH(
        wblt_to_swap, 0, back_to_weth, screamsh, 2**256 - 1, {"from": screamsh}
    )
    assert bmx.balanceOf(router) == 0
    assert weth.balanceOf(router) == 0
    assert usdc.balanceOf(router) == 0
    assert w_blt.balanceOf(router) == 0
    assert w_blt.balanceOf(screamsh) == 0
    assert screamsh.balance() > before_eth
    print("✅  Swapped from wBLT back to ether")

    # swap for some BMX from ETH
    weth.approve(router, 2**256 - 1, {"from": screamsh})
    before = bmx.balanceOf(screamsh)
    before_eth = screamsh.balance()
    router.swapExactETHForTokens(
        weth_to_swap,
        0,
        weth_to_bmx,
        screamsh,
        2**256 - 1,
        {"from": screamsh, "value": 1e18},
    )
    assert bmx.balanceOf(screamsh) > before
    assert bmx.balanceOf(router) == 0
    assert weth.balanceOf(router) == 0
    assert usdc.balanceOf(router) == 0
    assert w_blt.balanceOf(router) == 0
    assert screamsh.balance() < before_eth
    print("✅  Swapped ether to BMX")

    # approve our BMX, back to ETH
    bmx.approve(router, 2**256 - 1, {"from": screamsh})
    bmx_to_usdc = [
        (bmx.address, w_blt.address, False),
        (w_blt.address, usdc.address, False),
    ]
    before_eth = screamsh.balance()
    bmx_to_swap = bmx.balanceOf(screamsh)
    before = usdc.balanceOf(screamsh)
    router.swapExactTokensForETH(
        bmx_to_swap, 0, bmx_to_usdc, screamsh.address, 2**256 - 1, {"from": screamsh}
    )
    assert usdc.balanceOf(screamsh) > before
    assert bmx.balanceOf(router) == 0
    assert weth.balanceOf(router) == 0
    assert usdc.balanceOf(router) == 0
    assert w_blt.balanceOf(router) == 0
    assert bmx.balanceOf(screamsh) == 0
    assert screamsh.balance() > before_eth
    print("✅  Swapped back from BMX to ether")


def test_long_route_swap(
    bmx,
    screamsh,
    w_blt,
    router,
    weth,
    factory,
    usdc,
):
    # whales deposit USDC and WETH to give us some flexibility, USDC-WETH pool on aerodrome
    token_whale = accounts.at("0xB4885Bc63399BF5518b994c1d0C153334Ee579D0", force=True)
    weth.approve(router, 2**256 - 1, {"from": token_whale})
    usdc.approve(router, 2**256 - 1, {"from": token_whale})

    weth_to_wblt = [
        (weth.address, w_blt.address, False),
    ]
    weth_to_swap = 10e18

    usdc_to_wblt = [
        (usdc.address, w_blt.address, False),
    ]
    usdc_to_swap = 10_000e6

    router.swapExactTokensForTokens(
        weth_to_swap, 0, weth_to_wblt, token_whale, 2**256 - 1, {"from": token_whale}
    )

    router.swapExactTokensForTokens(
        usdc_to_swap, 0, usdc_to_wblt, token_whale, 2**256 - 1, {"from": token_whale}
    )

    assert bmx.balanceOf(router) == 0
    assert weth.balanceOf(router) == 0
    assert usdc.balanceOf(router) == 0
    assert w_blt.balanceOf(router) == 0
    print("✅  Lots of deposits to wBLT")

    # swap for some BMX via WETH -> USDC
    weth.approve(router, 2**256 - 1, {"from": screamsh})
    weth_to_swap = 1e15
    before = bmx.balanceOf(screamsh)
    weth_to_bmx_long = [
        (weth.address, usdc.address, False),
        (usdc.address, w_blt.address, False),
        (w_blt.address, bmx.address, False),
    ]
    router.swapExactTokensForTokens(
        weth_to_swap, 0, weth_to_bmx_long, screamsh, 2**256 - 1, {"from": screamsh}
    )
    assert bmx.balanceOf(screamsh) > before
    assert bmx.balanceOf(router) == 0
    assert weth.balanceOf(router) == 0
    assert usdc.balanceOf(router) == 0
    assert w_blt.balanceOf(router) == 0
    print("✅  Long swap WETH -> USDC -> BMX")

    # swap back to USDC now via WETH
    bmx.approve(router, 2**256 - 1, {"from": screamsh})
    bmx_to_swap = bmx.balanceOf(screamsh) / 2
    before = usdc.balanceOf(screamsh)
    bmx_to_usdc_long = [
        (bmx.address, w_blt.address, False),
        (w_blt.address, weth.address, False),
        (weth.address, usdc.address, False),
    ]
    router.swapExactTokensForTokens(
        bmx_to_swap,
        0,
        bmx_to_usdc_long,
        screamsh.address,
        2**256 - 1,
        {"from": screamsh},
    )
    assert usdc.balanceOf(screamsh) > before
    assert bmx.balanceOf(router) == 0
    assert weth.balanceOf(router) == 0
    assert usdc.balanceOf(router) == 0
    assert w_blt.balanceOf(router) == 0
    print("✅  Long swap BMX -> WETH -> USDC")


def test_add_liq(
    bmx,
    screamsh,
    w_blt,
    router,
    weth,
    factory,
    usdc,
):

    # add liquidity
    # swap for some BMX
    weth.approve(router, 2**256 - 1, {"from": screamsh})
    bmx.approve(router, 2**256 - 1, {"from": screamsh})
    weth_to_swap = 1e18
    weth_to_bmx = [
        (weth.address, w_blt.address, False),
        (w_blt.address, bmx.address, False),
    ]
    before = bmx.balanceOf(screamsh)
    router.swapExactTokensForTokens(
        weth_to_swap, 0, weth_to_bmx, screamsh, 2**256 - 1, {"from": screamsh}
    )
    assert bmx.balanceOf(screamsh) > before
    lp = Contract("0xd272920b2b4ebee362a887451edbd6d68a76e507")
    assert lp.balanceOf(screamsh) == 0
    router.addLiquidity(
        weth, 1e18, bmx, 50e18, 50e18, 0, 0, screamsh.address, {"from": screamsh}
    )
    assert bmx.balanceOf(router) == 0
    assert weth.balanceOf(router) == 0
    assert usdc.balanceOf(router) == 0
    assert w_blt.balanceOf(router) == 0
    assert lp.balanceOf(router) == 0
    assert lp.balanceOf(screamsh) > 0
    print("✅  Added liquidity for BMX-wBLT with WETH")


def test_add_liq_ether(
    bmx,
    screamsh,
    w_blt,
    router,
    weth,
    factory,
    usdc,
):
    # ETH whale sends some to screamsh
    eth_whale = accounts.at("0x224D8Fd7aB6AD4c6eb4611Ce56EF35Dec2277F03", force=True)
    eth_whale.transfer(screamsh, 5e18)
    assert screamsh.balance() > 1e18

    # add liquidity
    # swap for some BMX
    weth.approve(router, 2**256 - 1, {"from": screamsh})
    bmx.approve(router, 2**256 - 1, {"from": screamsh})
    weth_to_swap = 1e18
    weth_to_bmx = [
        (weth.address, w_blt.address, False),
        (w_blt.address, bmx.address, False),
    ]
    before = bmx.balanceOf(screamsh)
    router.swapExactTokensForTokens(
        weth_to_swap, 0, weth_to_bmx, screamsh, 2**256 - 1, {"from": screamsh}
    )
    assert bmx.balanceOf(screamsh) > before
    lp = Contract("0xd272920b2b4ebee362a887451edbd6d68a76e507")
    assert lp.balanceOf(screamsh) == 0

    router.addLiquidityETH(
        1e18,
        bmx,
        500e18,
        500e18,
        0,
        0,
        screamsh.address,
        {"from": screamsh, "value": 1e18},
    )
    assert bmx.balanceOf(router) == 0
    assert weth.balanceOf(router) == 0
    assert usdc.balanceOf(router) == 0
    assert w_blt.balanceOf(router) == 0
    assert lp.balanceOf(router) == 0
    assert lp.balanceOf(screamsh) > 0
    print("✅  Added liquidity for BMX-wBLT with Ether")


def test_remove_liq(
    bmx,
    screamsh,
    w_blt,
    router,
    weth,
    factory,
    usdc,
):
    # whales deposit USDC and WETH to give us some flexibility, USDC-WETH pool on aerodrome
    token_whale = accounts.at("0xB4885Bc63399BF5518b994c1d0C153334Ee579D0", force=True)
    weth.approve(router, 2**256 - 1, {"from": token_whale})
    usdc.approve(router, 2**256 - 1, {"from": token_whale})

    weth_to_wblt = [
        (weth.address, w_blt.address, False),
    ]
    weth_to_swap = 10e18

    usdc_to_wblt = [
        (usdc.address, w_blt.address, False),
    ]
    usdc_to_swap = 10_000e6

    router.swapExactTokensForTokens(
        weth_to_swap, 0, weth_to_wblt, token_whale, 2**256 - 1, {"from": token_whale}
    )

    router.swapExactTokensForTokens(
        usdc_to_swap, 0, usdc_to_wblt, token_whale, 2**256 - 1, {"from": token_whale}
    )

    assert bmx.balanceOf(router) == 0
    assert weth.balanceOf(router) == 0
    assert usdc.balanceOf(router) == 0
    assert w_blt.balanceOf(router) == 0
    print("✅  Lots of deposits to wBLT")

    # add liquidity
    # swap for some BMX
    weth.approve(router, 2**256 - 1, {"from": screamsh})
    bmx.approve(router, 2**256 - 1, {"from": screamsh})
    weth_to_swap = 1e18
    weth_to_bmx = [
        (weth.address, w_blt.address, False),
        (w_blt.address, bmx.address, False),
    ]
    before = bmx.balanceOf(screamsh)
    router.swapExactTokensForTokens(
        weth_to_swap, 0, weth_to_bmx, screamsh, 2**256 - 1, {"from": screamsh}
    )
    assert bmx.balanceOf(screamsh) > before
    lp = Contract("0xd272920b2b4ebee362a887451edbd6d68a76e507")
    assert lp.balanceOf(screamsh) == 0
    router.addLiquidity(
        weth, 1e18, bmx, 50e18, 50e18, 0, 0, screamsh.address, {"from": screamsh}
    )
    assert bmx.balanceOf(router) == 0
    assert weth.balanceOf(router) == 0
    assert usdc.balanceOf(router) == 0
    assert w_blt.balanceOf(router) == 0
    assert lp.balanceOf(router) == 0
    assert lp.balanceOf(screamsh) > 0
    print("✅  Added liquidity for BMX-wBLT with WETH")
    chain.sleep(1)
    chain.mine(1)

    # remove our liq
    lp.approve(router, 2**256 - 1, {"from": screamsh})
    before_bmx = bmx.balanceOf(screamsh)
    before_weth = weth.balanceOf(screamsh)
    router.removeLiquidity(
        weth, bmx, lp.balanceOf(screamsh), 0, 0, screamsh.address, {"from": screamsh}
    )
    assert before_bmx < bmx.balanceOf(screamsh)
    assert before_weth < weth.balanceOf(screamsh)
    assert bmx.balanceOf(router) == 0
    assert weth.balanceOf(router) == 0
    assert usdc.balanceOf(router) == 0
    assert w_blt.balanceOf(router) == 0
    assert lp.balanceOf(router) == 0
    assert lp.balanceOf(screamsh) == 0
    print("✅  Removed liquidity for BMX-wBLT to WETH+BMX")


def test_remove_liq_ether(
    bmx,
    screamsh,
    w_blt,
    router,
    weth,
    factory,
    usdc,
):
    # whales deposit USDC and WETH to give us some flexibility, USDC-WETH pool on aerodrome
    token_whale = accounts.at("0xB4885Bc63399BF5518b994c1d0C153334Ee579D0", force=True)
    weth.approve(router, 2**256 - 1, {"from": token_whale})
    usdc.approve(router, 2**256 - 1, {"from": token_whale})

    weth_to_wblt = [
        (weth.address, w_blt.address, False),
    ]
    weth_to_swap = 10e18

    usdc_to_wblt = [
        (usdc.address, w_blt.address, False),
    ]
    usdc_to_swap = 10_000e6

    router.swapExactTokensForTokens(
        weth_to_swap, 0, weth_to_wblt, token_whale, 2**256 - 1, {"from": token_whale}
    )

    router.swapExactTokensForTokens(
        usdc_to_swap, 0, usdc_to_wblt, token_whale, 2**256 - 1, {"from": token_whale}
    )

    assert bmx.balanceOf(router) == 0
    assert weth.balanceOf(router) == 0
    assert usdc.balanceOf(router) == 0
    assert w_blt.balanceOf(router) == 0
    print("✅  Lots of deposits to wBLT")

    # add liquidity
    # swap for some BMX
    weth.approve(router, 2**256 - 1, {"from": screamsh})
    bmx.approve(router, 2**256 - 1, {"from": screamsh})
    weth_to_swap = 1e18
    weth_to_bmx = [
        (weth.address, w_blt.address, False),
        (w_blt.address, bmx.address, False),
    ]
    before = bmx.balanceOf(screamsh)
    router.swapExactTokensForTokens(
        weth_to_swap, 0, weth_to_bmx, screamsh, 2**256 - 1, {"from": screamsh}
    )
    assert bmx.balanceOf(screamsh) > before
    lp = Contract("0xd272920b2b4ebee362a887451edbd6d68a76e507")
    assert lp.balanceOf(screamsh) == 0
    router.addLiquidity(
        weth, 1e18, bmx, 50e18, 50e18, 0, 0, screamsh.address, {"from": screamsh}
    )
    assert bmx.balanceOf(router) == 0
    assert weth.balanceOf(router) == 0
    assert usdc.balanceOf(router) == 0
    assert w_blt.balanceOf(router) == 0
    assert lp.balanceOf(router) == 0
    assert lp.balanceOf(screamsh) > 0
    print("✅  Added liquidity for BMX-wBLT with WETH")
    chain.sleep(1)
    chain.mine(1)

    # remove our liq
    lp.approve(router, 2**256 - 1, {"from": screamsh})
    before_bmx = bmx.balanceOf(screamsh)
    before_eth = screamsh.balance()
    router.removeLiquidityETH(
        bmx, lp.balanceOf(screamsh), 0, 0, screamsh.address, {"from": screamsh}
    )
    assert before_bmx < bmx.balanceOf(screamsh)
    assert before_eth < screamsh.balance()
    assert bmx.balanceOf(router) == 0
    assert weth.balanceOf(router) == 0
    assert usdc.balanceOf(router) == 0
    assert w_blt.balanceOf(router) == 0
    assert lp.balanceOf(router) == 0
    assert lp.balanceOf(screamsh) == 0
    print("✅  Removed liquidity for BMX-wBLT to ether+BMX")


def test_options(
    bmx,
    screamsh,
    w_blt,
    router,
    weth,
    factory,
    usdc,
    gauge,
    obmx,
):

    # testing oBMX
    weth.approve(router, 2**256 - 1, {"from": screamsh})
    obmx.approve(router, 2**256 - 1, {"from": screamsh})
    router.exerciseLpWithUnderlying(
        weth.address, 1e17, 1e18, 35, 2**256 - 1, {"from": screamsh}
    )
    assert bmx.balanceOf(router) == 0
    assert weth.balanceOf(router) == 0
    assert usdc.balanceOf(router) == 0
    assert w_blt.balanceOf(router) == 0
    assert lp.balanceOf(router) == 0
    assert gauge.balanceOf(screamsh) > 0
