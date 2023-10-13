import pytest
from brownie import config, Contract, ZERO_ADDRESS, chain, interface, accounts
from eth_abi import encode_single
import requests


@pytest.fixture(scope="function", autouse=True)
def isolate(fn_isolation):
    pass


# set this for if we want to use tenderly or not; mostly helpful because with brownie.reverts fails in tenderly forks.
use_tenderly = False

# use this to set what chain we use. 1 for ETH, 250 for fantom, 10 optimism, 42161 arbitrum, 8453 base
chain_used = 250


@pytest.fixture(scope="session")
def tests_using_tenderly():
    yes_or_no = use_tenderly
    yield yes_or_no


# useful because it doesn't crash when sometimes ganache does, "works" in coverage testing but then doesn't actually write any data lol
# if we're using anvil, make sure to use the correct network (ftm-anvil-fork vs ftm-main-fork)
use_anvil = False


@pytest.fixture(scope="session")
def tests_using_anvil():
    yes_or_no = use_anvil
    yield yes_or_no


@pytest.fixture(scope="session", autouse=use_anvil)
def fun_with_anvil(web3):
    web3.manager.request_blocking("anvil_setNextBlockBaseFeePerGas", ["0x0"])


################################################## TENDERLY DEBUGGING ##################################################

# change autouse to True if we want to use this fork to help debug tests
@pytest.fixture(scope="session", autouse=use_tenderly)
def tenderly_fork(web3, chain):
    import requests
    import os

    # Get env variables
    TENDERLY_ACCESS_KEY = os.environ.get("TENDERLY_ACCESS_KEY")
    TENDERLY_USER = os.environ.get("TENDERLY_USER")
    TENDERLY_PROJECT = os.environ.get("TENDERLY_PROJECT")

    # Construct request
    url = f"https://api.tenderly.co/api/v1/account/{TENDERLY_USER}/project/{TENDERLY_PROJECT}/fork"
    headers = {"X-Access-Key": str(TENDERLY_ACCESS_KEY)}
    data = {
        "network_id": str(chain.id),
    }

    # Post request
    response = requests.post(url, json=data, headers=headers)

    # Parse response
    fork_id = response.json()["simulation_fork"]["id"]

    # Set provider to your new Tenderly fork
    fork_rpc_url = f"https://rpc.tenderly.co/fork/{fork_id}"
    tenderly_provider = web3.HTTPProvider(fork_rpc_url, {"timeout": 600})
    web3.provider = tenderly_provider
    print(
        f"https://dashboard.tenderly.co/{TENDERLY_USER}/{TENDERLY_PROJECT}/fork/{fork_id}"
    )


################################################ UPDATE THINGS BELOW HERE ################################################

# use this to test both exercising for WETH and underlying
@pytest.fixture(
    params=[
        True,
        False,
    ],
    ids=["receive_underlying", "receive_weth"],
    scope="function",
)
def receive_underlying(request):
    yield request.param


# use this to simulate positive slippage (times when spot price is higher than TWAP price)
@pytest.fixture(
    params=[
        True,
        False,
    ],
    ids=["buy_underlying", "do_nothing"],
    scope="function",
)
def buy_underlying(request):
    yield request.param


@pytest.fixture(scope="function")
def router():
    router = Contract("0x2E14B53E2cB669f3A974CeaF6C735e134F3Aa9BC")  # normal FVM router
    yield router


@pytest.fixture(scope="function")
def gauge():
    gauge = Contract("0xa3643a5d5B672a267199227CD3E95eD0B41DBD52")  # FVM-WFTM gauge
    yield gauge


@pytest.fixture(scope="session")
def screamsh():
    yield accounts.at("0x89955a99552F11487FFdc054a6875DF9446B2902", force=True)


@pytest.fixture(scope="session")
def ofvm_whale():
    yield accounts.at("0x9aCf8D0315094d33Aa6875B673EB126483C3A2c0", force=True)


@pytest.fixture(scope="session")
def fvm_whale():
    yield accounts.at("0xc350eEd2C03D422349Df0398072a2F35A37E4Ad5", force=True)


@pytest.fixture(scope="session")
def wftm_whale():
    yield accounts.at("0x3E923747cA2675E096d812c3b24846aC39aeD645", force=True)


@pytest.fixture(scope="session")
def wftm():
    yield Contract("0x21be370D5312f44cB42ce377BC9b8a0cEF1A4C83")


@pytest.fixture(scope="session")
def fvm():
    yield interface.IERC20("0x07BB65fAaC502d4996532F834A1B7ba5dC32Ff96")


@pytest.fixture(scope="session")
def ofvm():
    yield Contract("0xF9EDdca6B1e548B0EC8cDDEc131464F462b8310D")


# our dump helper
@pytest.fixture(scope="function")
def fvm_exercise_helper(SimpleExerciseHelperFantomWFTM, screamsh):
    fvm_exercise_helper = screamsh.deploy(
        SimpleExerciseHelperFantomWFTM,
    )
    #     fvm_exercise_helper = Contract("0x758aD6A8798F881E4f264aEAA4903eCde86da729")
    yield fvm_exercise_helper
