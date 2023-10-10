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
chain_used = 8453


@pytest.fixture(scope="session")
def tests_using_tenderly():
    yes_or_no = use_tenderly
    yield yes_or_no


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
    router = Contract("0x70FfF9B84788566065f1dFD8968Fb72F798b9aE5")  # normal BVM router
    yield router


@pytest.fixture(scope="function")
def gauge():
    gauge = Contract("0x3f5129112754D4fBE7ab228C2D5E312b2Bc79A06")  # BVM-WETH gauge
    yield gauge


@pytest.fixture(scope="session")
def screamsh():
    yield accounts.at("0x89955a99552F11487FFdc054a6875DF9446B2902", force=True)


@pytest.fixture(scope="session")
def obvm_whale():
    yield accounts.at("0x06b16991B53632C2362267579AE7C4863c72fDb8", force=True)


@pytest.fixture(scope="session")
def bvm_whale():
    yield accounts.at("0x91F85d68B413dE823684c891db515B0390a02512", force=True)


@pytest.fixture(scope="session")
def weth_whale():
    yield accounts.at("0xB4885Bc63399BF5518b994c1d0C153334Ee579D0", force=True)


@pytest.fixture(scope="session")
def weth():
    yield Contract("0x4200000000000000000000000000000000000006")


@pytest.fixture(scope="session")
def bvm():
    yield interface.IERC20("0xd386a121991E51Eab5e3433Bf5B1cF4C8884b47a")


@pytest.fixture(scope="session")
def obvm():
    yield Contract("0x762eb51D2e779EeEc9B239FFB0B2eC8262848f3E")


# our dump helper
@pytest.fixture(scope="function")
def bvm_exercise_helper(SimpleExerciseHelperBaseWETH, screamsh):
    bvm_exercise_helper = screamsh.deploy(
        SimpleExerciseHelperBaseWETH,
    )
    yield bvm_exercise_helper
