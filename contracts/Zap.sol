// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.15;

// These are the core Yearn libraries
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@yearnvaults/contracts/BaseStrategy.sol";

interface IOracle {
    // pull our asset price, in usdc, via yearn's oracle
    function getPriceUsdcRecommended(
        address tokenAddress
    ) external view returns (uint256);
}

interface IMorphex is IERC20 {
    function getVestedAmount(address) external view returns (uint256);

    function claimable(address) external view returns (uint256);

    function getMaxVestableAmount(address) external view returns (uint256);

    function pairAmounts(address) external view returns (uint256);

    function depositBalances(address, address) external view returns (uint256);

    function handleRewards(bool, bool, bool, bool, bool, bool, bool) external;

    function withdraw() external;

    function deposit(uint256) external;

    function unstakeEsGmx(uint256) external;

    function stakeEsGmx(uint256) external;

    function unstakeGmx(uint256) external;

    function signalTransfer(address) external;

    function acceptTransfer(address) external;

    function getPairAmount(address, uint256) external view returns (uint256);

    function mintAndStakeGlp(
        address,
        uint256,
        uint256,
        uint256
    ) external returns (uint256);
}

contract Zap {
    using SafeERC20 for IERC20;
    /* ========== STATE VARIABLES ========== */

    /// @notice Morphex's reward router.
    /// @dev Used for staking/unstaking assets and claiming rewards.
    IMorphex public constant rewardRouter =
        IMorphex(0x20De7f8283D377fA84575A26c9D484Ee40f55877);

    /// @notice This contract manages esMPX vesting with MLP as collateral.
    /// @dev We also read vesting data from here.
    IMorphex public constant vestedMlp =
        IMorphex(0xdBa3A9993833595eAbd2cDE1c235904ad0fD0b86);

    /// @notice Address of Morphex's vanilla token.
    /// @dev We should only recieve this from vesting esMPX.
    IMorphex public constant mpx =
        IMorphex(0x66eEd5FF1701E6ed8470DC391F05e27B1d0657eb);

    /// @notice Address of escrowed MPX.
    /// @dev Must be vested over 1 year to convert to MPX.
    IMorphex public constant esMpx =
        IMorphex(0xe0f606e6730bE531EeAf42348dE43C2feeD43505);

    /// @notice Address for staked MPX.
    /// @dev Receipt token for staking esMPX or MPX.
    IMorphex public constant sMpx =
        IMorphex(0xa4157E273D88ff16B3d8Df68894e1fd809DbC007);

    /// @notice MLP, the LP token for the basket of collateral assets on Morphex.
    /// @dev This is staked for our want token.
    IMorphex public constant mlp =
        IMorphex(0xd5c313DE2d33bf36014e6c659F13acE112B80a8E);

    /// @notice fsMLP, the representation of our staked MLP that the strategy holds.
    /// @dev When reserved for vesting, this is burned for vestedMlp.
    IMorphex public constant fsMlp =
        IMorphex(0x49A97680938B4F1f73816d1B70C3Ab801FAd124B);

    /// @notice Address for WFTM, our fee token.
    IERC20 public constant wftm =
        IERC20(0x21be370D5312f44cB42ce377BC9b8a0cEF1A4C83);

    /// @notice Minimum profit size in USDC that we want to harvest.
    /// @dev Only used in harvestTrigger.
    uint256 public harvestProfitMinInUsdc;

    /// @notice Maximum profit size in USDC that we want to harvest (ignore gas price once we get here).
    /// @dev Only used in harvestTrigger.
    uint256 public harvestProfitMaxInUsdc;

    /// @notice The percent of our esMPX we would like to vest; the remainder will be staked.
    /// @dev Max 10,000 = 100%. Defaults to zero.
    uint256 public percentToVest;

    // we use this to be able to adjust our strategy's name
    string internal stratName;

    // this means all of our fee values are in basis points
    uint256 internal constant FEE_DENOMINATOR = 10_000;

    /* ========== CONSTRUCTOR ========== */

    constructor(address _vault) BaseStrategy(_vault) {
        // want = sMLP
        address mlpManager = 0xA3Ea99f8aE06bA0d9A6Cf7618d06AEa4564340E9;
        wftm.approve(address(mlpManager), type(uint256).max);
        mpx.approve(address(sMpx), type(uint256).max);

        // set up our max delay
        maxReportDelay = 7 days;

        // set our min and max profit
        harvestProfitMinInUsdc = 1_000e6;
        harvestProfitMaxInUsdc = 10_000e6;

        // set our strategy's name
        stratName = "StrategyMLPStaker";
    }

    /* ========== VIEWS ========== */

    /// @notice Strategy name.
    function name() external view override returns (string memory) {
        return stratName;
    }

    /* ========== CORE STRATEGY FUNCTIONS ========== */

    /// @notice Provide any loose WFTM to MLP and stake it.
    /// @dev May only be called by vault managers.
    /// @return Amount of MLP staked from profits.
    function mintAndStake(uint256 _amount) internal returns (uint256) {
        wftm.transferFrom(msg.sender, address(this), _amount);
        uint256 newMlp = rewardRouter.mintAndStakeGlp(
                address(wftm),
                _amount,
                0,
                0
            );
        }
        return newMlp;
    }


}
