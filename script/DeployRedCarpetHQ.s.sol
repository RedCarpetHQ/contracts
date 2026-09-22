// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "forge-std/Script.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/Registry.sol";
import "../src/BaseCampaign.sol";
import "../src/SingleRoundCampaign.sol";
import "../src/CampaignAdmin.sol";
import "../src/MultiRoundCampaign.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/MarketMulticall.sol";
import "../src/MinimumERC20.sol";
import "../src/TestUSDR.sol";
import "../src/HybridPriceOracle.sol";
import "../src/RiskOracle.sol";
import "../src/logic/JumpRateModel.sol";
import "../src/UnifiedVault.sol";
import "../src/LendingManager.sol";
import "../src/FeeDistributor.sol";
import "../src/DividendDistributor.sol";
import "../src/Contest.sol";
import "../src/KeeperRegistry.sol";
import "../src/OptimisticPriceOracle.sol";
import "../src/BurnRedemption.sol";
import "../src/SurveySnapshot.sol";
import "../src/CampaignFeeManager.sol";
import "../src/logic/InterestLogic.sol";
import "../src/logic/LendingLogic.sol";
import "../src/logic/StabilityLogic.sol";
import "../src/logic/MultiRoundLogic.sol";
import "../src/logic/TierLogic.sol";
import "../src/storage/VolumeTracker.sol";
import "../src/VaultFactory.sol";

/**
 * @title AddressParser
 * @notice Utility library to parse comma-separated addresses from string
 */
library AddressParser {
    function parseAddresses(string memory str) internal pure returns (address[] memory) {
        if (bytes(str).length == 0) {
            return new address[](0);
        }

        // Count commas to determine array size
        uint256 count = 1;
        for (uint256 i = 0; i < bytes(str).length; i++) {
            if (bytes(str)[i] == ',') {
                count++;
            }
        }

        address[] memory addresses = new address[](count);
        uint256 start = 0;
        uint256 index = 0;

        for (uint256 i = 0; i <= bytes(str).length; i++) {
            if (i == bytes(str).length || bytes(str)[i] == ',') {
                // Extract substring for this address
                uint256 length = i - start;
                bytes memory addrBytes = new bytes(length);
                for (uint256 j = 0; j < length; j++) {
                    addrBytes[j] = bytes(str)[start + j];
                }

                // Convert to address (skip "0x" prefix if present)
                addresses[index] = toAddress(string(addrBytes));
                index++;
                start = i + 1;
            }
        }

        return addresses;
    }

    function toAddress(string memory str) internal pure returns (address addr) {
        bytes memory strBytes = bytes(str);

        // Skip "0x" prefix if present
        uint256 start = 0;
        if (strBytes.length >= 2 && strBytes[0] == '0' && strBytes[1] == 'x') {
            start = 2;
        }

        // Convert hex string to address
        uint256 result = 0;
        for (uint256 i = start; i < strBytes.length; i++) {
            uint8 c = uint8(strBytes[i]);
            if (c >= 48 && c <= 57) { // 0-9
                result = result * 16 + (c - 48);
            } else if (c >= 65 && c <= 70) { // A-F
                result = result * 16 + (c - 55);
            } else if (c >= 97 && c <= 102) { // a-f
                result = result * 16 + (c - 87);
            } else {
                revert("Invalid hex character");
            }
        }

        return address(uint160(result));
    }
}

/**
 * @title DeployRedCarpetHQ
 * @notice V3 deployment script for the RedCarpetHQ (single-owner / direct deploy)
 * @dev Deploys all contracts AND applies the full configuration inline, producing the same
 *      end-state that GenerateMultisigTransactions.s.sol + VerifyMultisigSetup.s.sol define
 *      for the multisig flow. All config calls here are executed directly by the deployer,
 *      so OWNER_ADDRESS must be the deployer address.
 *
 * V3 ARCHITECTURE CHANGES:
 * - UnifiedVault: Single ERC4626 vault per token (replaces 5-contract stack)
 * - FeeDistributor: Central fee distribution (40% FEE_SAFE, 40% Contest, 10% Vault, 10% Producer)
 * - RiskOracle: Risk tier assessment (GREEN/YELLOW/RED)
 * - TierLogic + VolumeTracker: volume-based fee discount tiers
 * - Simplified Market (all fees to FeeDistributor)
 * - Simplified Contest (no creator rewards - handled by FeeDistributor)
 * - RegistryV2: Upgradeable UUPS proxy pattern for future upgrades
 *
 * DEPLOYMENT ORDER:
 * 1. Core Infrastructure (payment token, Upgradeable Registry, Token Implementation)
 * 2. Campaign & Market System
 * 3. Oracle System (Hybrid + Optimistic + Risk + RateModel)
 * 4. Tier & Logic Contracts (VolumeTracker, TierLogic, Interest/Lending/Stability/MultiRound)
 * 5. Lending System (VaultFactory + LendingManager)
 * 6. Fee Distribution System
 * 7. Contest System
 * 8. Keeper Registry
 * 9. Survey & Redemption System
 * 10. Inline configuration (mirrors GenerateMultisigTransactions.s.sol exactly)
 *
 * ENV VARS:
 * - DEPLOYER_PRIVATE_KEY (required)
 * - OWNER_ADDRESS (required — must be the deployer for this script)
 * - FEE_SAFE_ADDRESS (required)
 * - PRODUCTION (optional, default false) — true uses USDC_ADDRESS, false uses TestUSDR
 * - USDC_ADDRESS (required when PRODUCTION=true)
 * - TEST_USDR_ADDRESS (optional — reuse existing TestUSDR instead of deploying)
 * - ADMIN_ADDRESSES (optional, comma-separated — set as screeners)
 *
 */
contract DeployRedCarpetHQ is Script {
    using AddressParser for string;
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address owner = vm.envAddress("OWNER_ADDRESS");
        address feeWallet = vm.envAddress("FEE_SAFE_ADDRESS");
        bool production = vm.envOr("PRODUCTION", false);

        // Payment token: real USDC in production, TestUSDR otherwise
        address USDC;
        address testUSDR;
        if (production) {
            USDC = vm.envAddress("USDC_ADDRESS");
            console.log("Production mode: using USDC at:", USDC);
        } else {
            // Check if TEST_USDR_ADDRESS is set (for redeployment without USDR)
            try vm.envAddress("TEST_USDR_ADDRESS") returns (address _testUSDR) {
                testUSDR = _testUSDR;
                console.log("Using existing Test USDR at:", testUSDR);
            } catch {
                testUSDR = address(0);
            }
        }
        address paymentToken = production ? USDC : testUSDR;

        // Parse admin addresses from environment variable (comma-delimited, no quotes)
        address[] memory adminAddresses = new address[](0);
        try vm.envString("ADMIN_ADDRESSES") returns (string memory adminAddressesStr) {
            adminAddresses = adminAddressesStr.parseAddresses();
        } catch {
            // ADMIN_ADDRESSES not set, continue with empty array
        }

        vm.startBroadcast(deployerPrivateKey);

        console.log("\n========================================");
        console.log("REDCARPETHQ DEPLOYMENT");
        console.log("========================================\n");
        console.log("Owner:", owner);
        console.log("Deployer:", msg.sender);
        console.log("Fee Safe:", feeWallet);
        console.log("Production:", production);

        // ========== PHASE 1: CORE INFRASTRUCTURE ==========
        console.log("\n=== PHASE 1: Core Infrastructure ===\n");

        // 1. Deploy Test USDR if not already deployed (testnet only)
        if (testUSDR == address(0) && !production) {
            TestUSDR usdr = new TestUSDR(owner);
            testUSDR = address(usdr);
            paymentToken = testUSDR;
            console.log("1. Test USDR deployed at:", testUSDR);
        } else {
            console.log("1. Using existing payment token at:", paymentToken);
        }

        // 2. Deploy MinimumERC20 Implementation
        MinimumERC20 tokenImpl = new MinimumERC20();
        console.log("2. MinimumERC20 Implementation:", address(tokenImpl));

        // 3. Deploy Upgradeable Registry (UUPS Pattern)
        console.log("3. Deploying Upgradeable Registry (UUPS)...");

        // 3a. Deploy implementation
        Registry registryImplementation = new Registry();
        console.log("   3a. Registry Implementation:", address(registryImplementation));

        // 3b. Encode initialize call
        bytes memory initData = abi.encodeWithSelector(
            Registry.initialize.selector,
            owner
        );

        // 3c. Deploy proxy
        ERC1967Proxy registryProxy = new ERC1967Proxy(
            address(registryImplementation),
            initData
        );
        console.log("   3b. Registry Proxy:", address(registryProxy));

        // 3d. Wrap proxy in Registry interface
        Registry registry = Registry(address(registryProxy));
        console.log("   3c. Registry (Upgradeable):", address(registry));
        console.log("   - Pattern: UUPS (Universal Upgradeable Proxy Standard)");
        console.log("   - Owner can upgrade via upgradeToAndCall()");

        // 4. Deploy DividendDistributor (reads USDC from Registry dynamically)
        DividendDistributor dividendDistributor = new DividendDistributor(
            address(registry)
        );
        console.log("4. DividendDistributor:", address(dividendDistributor));

        // ========== PHASE 2: CAMPAIGN & MARKET SYSTEM ==========
        console.log("\n=== PHASE 2: Campaign & Market System ===\n");

        // 5a. Deploy CampaignAdmin (shared admin functions)
        CampaignAdmin campaignAdmin = new CampaignAdmin(
            owner,
            address(registry)
        );
        console.log("5a. CampaignAdmin:", address(campaignAdmin));

        // 5a-2. Deploy CampaignFeeManager (UI/integrator fee registry)
        CampaignFeeManager campaignFeeManager = new CampaignFeeManager(owner);
        console.log("5a-2. CampaignFeeManager:", address(campaignFeeManager));

        // 5b. Deploy SingleRoundCampaign (extends BaseCampaign) - UUPS Upgradeable
        console.log("5b. Deploying SingleRoundCampaign (UUPS Upgradeable)...");
        SingleRoundCampaign singleRoundCampaignImpl = new SingleRoundCampaign();
        console.log("    - Implementation:", address(singleRoundCampaignImpl));

        bytes memory singleRoundInitData = abi.encodeWithSelector(
            SingleRoundCampaign.initialize.selector,
            owner,
            address(registry),
            address(campaignAdmin)
        );
        ERC1967Proxy singleRoundProxy = new ERC1967Proxy(address(singleRoundCampaignImpl), singleRoundInitData);
        SingleRoundCampaign singleRoundCampaign = SingleRoundCampaign(address(singleRoundProxy));
        console.log("    - Proxy (SingleRoundCampaign):", address(singleRoundCampaign));

        // 5c. Deploy MultiRoundCampaign (extends BaseCampaign) - UUPS Upgradeable
        console.log("5c. Deploying MultiRoundCampaign (UUPS Upgradeable)...");
        MultiRoundCampaign multiRoundCampaignImpl = new MultiRoundCampaign();
        console.log("    - Implementation:", address(multiRoundCampaignImpl));

        bytes memory multiRoundInitData = abi.encodeWithSelector(
            MultiRoundCampaign.initialize.selector,
            owner,
            address(registry),
            address(campaignAdmin)
        );
        ERC1967Proxy multiRoundProxy = new ERC1967Proxy(address(multiRoundCampaignImpl), multiRoundInitData);
        MultiRoundCampaign multiRoundCampaign = MultiRoundCampaign(address(multiRoundProxy));
        console.log("    - Proxy (MultiRoundCampaign):", address(multiRoundCampaign));

        // 6. Deploy MarketMulticall (V3: simplified, all fees to FeeDistributor + multicall support)
        uint256 tradeFee = 250; // 2.5% in basis points
        MarketMulticall market = new MarketMulticall(
            owner,
            address(registry),
            tradeFee
        );
        console.log("6. MarketMulticall:", address(market));

        // ========== PHASE 3: ORACLE SYSTEM ==========
        console.log("\n=== PHASE 3: Oracle System ===\n");

        // 9. Deploy HybridPriceOracle (VWAP/TWAP)
        HybridPriceOracle hybridOracle = new HybridPriceOracle(owner);
        console.log("9. HybridPriceOracle:", address(hybridOracle));

        // 10. Deploy OptimisticPriceOracle
        OptimisticPriceOracle optimisticOracle = new OptimisticPriceOracle(
            owner,
            address(registry)
        );
        console.log("10. OptimisticPriceOracle:", address(optimisticOracle));

        // 11. Deploy RiskOracle (V3: with tier-based risk assessment)
        RiskOracle riskOracle = new RiskOracle(
            owner,
            address(registry)
        );
        console.log("11. RiskOracle:", address(riskOracle));
        console.log("    Tiers: GREEN (50% CF), YELLOW (40% CF), RED (30% CF)");

        // 12. Deploy JumpRateModel (uses tier-based presets from constructor)
        JumpRateModel rateModel = new JumpRateModel(owner);
        console.log("12. JumpRateModel:", address(rateModel));
        console.log("    Tier presets: GREEN (5.4% APR@kink), YELLOW (11.6% APR@kink), RED (33% APR@kink)");

        // ========== PHASE 3b: TIER & LOGIC CONTRACTS ==========
        console.log("\n=== PHASE 3b: Tier & Logic Contracts ===\n");

        // 12a. Deploy VolumeTracker (stores daily volume for tier qualification)
        VolumeTracker volumeTracker = new VolumeTracker(address(registry));
        console.log("12a. VolumeTracker:", address(volumeTracker));
        console.log("    - Immutable, uses Registry for address lookup");

        // 12b. Deploy TierLogic (calculates fee discounts based on 30-day volume)
        TierLogic tierLogic = new TierLogic(address(registry));
        console.log("12b. TierLogic:", address(tierLogic));
        console.log("    - Bronze (100k): 50 bps | Silver (500k): 100 bps | Gold (2M): 150 bps");

        // 12c. Deploy InterestLogic
        InterestLogic interestLogic = new InterestLogic();
        console.log("12c. InterestLogic:", address(interestLogic));

        // 12d. Deploy LendingLogic
        LendingLogic lendingLogic = new LendingLogic();
        console.log("12d. LendingLogic:", address(lendingLogic));

        // 12e. Deploy StabilityLogic
        StabilityLogic stabilityLogic = new StabilityLogic();
        console.log("12e. StabilityLogic:", address(stabilityLogic));

        // 12f. Deploy MultiRoundLogic
        MultiRoundLogic multiRoundLogic = new MultiRoundLogic(owner);
        console.log("12f. MultiRoundLogic:", address(multiRoundLogic));

        // ========== PHASE 4: LENDING SYSTEM (V3 Simplified) ==========
        console.log("\n=== PHASE 4: Lending System (V3 Simplified) ===\n");

        // 13. Deploy VaultFactory
        VaultFactory vaultFactory = new VaultFactory(owner);
        console.log("13. VaultFactory:", address(vaultFactory));

        // 13a. Deploy LendingManager
        LendingManager lendingManager = new LendingManager(
            owner,
            address(registry)
        );
        console.log("13a. LendingManager:", address(lendingManager));

        // ========== PHASE 5: FEE DISTRIBUTION SYSTEM ==========
        console.log("\n=== PHASE 5: Fee Distribution System ===\n");

        // 14. Deploy FeeDistributor
        FeeDistributor feeDistributor = new FeeDistributor(
            owner,
            address(registry)
        );
        console.log("14. FeeDistributor:", address(feeDistributor));
        console.log("    Split: 40% FEE_SAFE, 40% Contest, 10% Vault, 10% Producer");

        // ========== PHASE 6: CONTEST SYSTEM ==========
        console.log("\n=== PHASE 6: Contest System ===\n");

        // 15. Deploy Contest
        Contest contest = new Contest(
            owner,
            address(registry)
        );
        console.log("15. Contest:", address(contest));

        // ========== PHASE 7: KEEPER REGISTRY ==========
        console.log("\n=== PHASE 7: Keeper Registry ===\n");

        // 17. Deploy KeeperRegistry
        KeeperRegistry keeperRegistry = new KeeperRegistry(owner, address(registry));
        console.log("17. KeeperRegistry:", address(keeperRegistry));

        // ========== PHASE 8: SURVEY & REDEMPTION SYSTEM ==========
        console.log("\n=== PHASE 8: Survey & Redemption System ===\n");

        // 18. Deploy BurnRedemption
        BurnRedemption burnRedemption = new BurnRedemption(owner, address(registry));
        console.log("18. BurnRedemption:", address(burnRedemption));

        // 19. Deploy SurveySnapshot
        SurveySnapshot surveySnapshot = new SurveySnapshot(owner, address(registry));
        console.log("19. SurveySnapshot:", address(surveySnapshot));

        // ========== PHASE 9: CONFIGURATION ==========
        // Mirrors GenerateMultisigTransactions.s.sol exactly — the same calls the
        // multisig executes post-deployment, applied here directly by the owner.
        console.log("\n=== PHASE 9: Protocol Configuration ===\n");

        // --- 9a. Registry authorizations ---
        registry.setAuthorizedContract(address(singleRoundCampaign), true);
        registry.setAuthorizedContract(address(multiRoundCampaign), true);
        registry.setAuthorizedContract(address(market), true);
        registry.setAuthorizedContract(address(lendingManager), true);
        registry.setAuthorizedContract(address(feeDistributor), true);
        console.log("9a. Authorized: SingleRound, MultiRound, Market, LendingManager, FeeDistributor");

        // --- 9b. Core Registry addresses ---
        registry.setUsdc(paymentToken);
        registry.setFeeWallet(feeWallet);
        registry.setFeeSafe(feeWallet);
        registry.setCampaignAddresses(
            address(singleRoundCampaign),
            address(campaignAdmin),
            address(multiRoundCampaign),
            address(tokenImpl),
            address(dividendDistributor)
        );
        registry.setMarket(address(market));
        console.log("9b. Core addresses set in Registry (USDC, FeeWallet, FeeSafe, Campaigns, Market)");

        // --- 9c. Oracle + logic addresses ---
        registry.setOracleAddresses(
            address(hybridOracle),
            address(riskOracle),
            address(optimisticOracle),
            address(rateModel)
        );
        registry.setLogicAddresses(
            address(interestLogic),
            address(lendingLogic),
            address(stabilityLogic),
            address(multiRoundLogic)
        );
        registry.setLendingManager(address(lendingManager));
        console.log("9c. Oracle + logic + LendingManager set in Registry");

        // --- 9d. System addresses (batch) + protocol safe ---
        registry.setSystemAddresses(
            address(feeDistributor),
            feeWallet,
            address(contest),
            address(keeperRegistry),
            address(burnRedemption),
            address(surveySnapshot)
        );
        registry.setProtocolSafe(feeWallet);
        registry.setCampaignFeeManager(address(campaignFeeManager));
        console.log("9d. System addresses, protocol safe, CampaignFeeManager set");

        // --- 9e. Tier system ---
        registry.setVolumeTracker(address(volumeTracker));
        registry.setTierLogic(address(tierLogic));
        console.log("9e. VolumeTracker + TierLogic set in Registry");

        // --- 9f. Admin screeners ---
        if (adminAddresses.length > 0) {
            for (uint256 i = 0; i < adminAddresses.length; i++) {
                campaignAdmin.setScreener(adminAddresses[i], true);
                console.log("   - Screener set:", adminAddresses[i]);
            }
        }

        // --- 9g. Market payment token ---
        market.setAcceptedPaymentToken(paymentToken, true);
        console.log("9g. Payment token accepted in Market:", paymentToken);

        // --- 9h. Oracle configuration ---
        hybridOracle.setRegistry(address(registry));
        hybridOracle.setAuthorizedUpdater(address(market), true);
        hybridOracle.setAuthorizedUpdater(address(lendingManager), true);
        console.log("9h. HybridPriceOracle: registry set, Market + LendingManager authorized");

        // --- 9i. Lending wiring ---
        vaultFactory.setLendingManager(address(lendingManager));
        lendingManager.setVaultFactory(address(vaultFactory));
        console.log("9i. VaultFactory <-> LendingManager connected");

        // --- 9j. Contest configuration ---
        contest.setSource(address(market), true);
        contest.setSource(address(feeDistributor), true);
        contest.setCollector(address(feeDistributor), true);
        contest.setDeadEpochSweepReward(uint128(1e6)); // 1 USDC gas incentive
        console.log("9j. Contest sources, collector, and sweep reward set");

        // ========== PHASE 10: PRODUCTION TIMING CONFIGURATION ==========
        // Same values VerifyMultisigSetup.s.sol Phase 9 asserts — applied on every
        // deployment (testnet included) so the deployed state matches the verifier.
        console.log("\n=== PHASE 10: Timing Configuration ===\n");

        optimisticOracle.updateConfig(
            uint256(24 hours),  // challengeWindow (contract enforces <= 24h)
            uint256(1000e6),    // bondAmount: 1000 USDC
            uint256(7 days),    // voteDuration
            uint256(1000)       // minQuorumBps: 10%
        );
        console.log("10a. OptimisticPriceOracle: 24h challenge, 7d vote, 1000 USDC bond, 10% quorum");

        hybridOracle.setDecayConfig(
            uint256(1 hours),  // MIN_UPDATE_INTERVAL
            uint256(14),       // PHASE1_DAYS
            uint256(30),       // PHASE2_DAYS
            uint256(60)        // MAX_DECAY_DAYS
        );
        console.log("10b. HybridPriceOracle decay: 1h update, 14/30/60d phases");

        hybridOracle.setDefaultConfig(
            uint256(4 hours),    // defaultStaleThreshold
            uint256(1000e6),     // defaultMinVolume24h
            uint256(10000e6),    // defaultTargetVolume
            uint256(100e6)       // defaultMinUpdateVolume
        );
        console.log("10c. HybridPriceOracle defaults: 4h stale, 1000 min vol, 10k target, 100 min update");

        contest.setEpochLength(uint32(7 days));
        console.log("10d. Contest epoch length: 7 days");

        dividendDistributor.setMinClaimPeriod(uint256(90 days));
        console.log("10e. DividendDistributor min claim period: 90 days");

        riskOracle.setTimingParameters(
            uint40(3600),       // EPOCH_SECS: 1 hour
            uint256(14 days),   // STALE_RED_THRESHOLD
            uint256(3 days),    // STALE_YELLOW_THRESHOLD
            uint256(30 days)    // BOOTSTRAP_DURATION
        );
        console.log("10f. RiskOracle timing: 1h epoch, 14d/3d staleness, 30d bootstrap");

        multiRoundLogic.setTimingParameters(
            uint256(2 days),    // MIN_ROUND_GAP
            uint256(30 days),   // CREATOR_FINALIZE_GRACE
            uint256(14 days)    // FAILED_ROUND_COOLDOWN
        );
        console.log("10g. MultiRoundLogic timing: 2d gap, 30d grace, 14d cooldown");

        console.log("\n[NOTE] UnifiedVault.MIN_DEPOSIT_DURATION is per-vault");
        console.log("[NOTE] Call vault.setMinDepositDuration(1 hours) for each vault post-creation");

        vm.stopBroadcast();

        // ========== DEPLOYMENT SUMMARY ==========
        console.log("\n========================================");
        console.log("V3 DEPLOYMENT SUMMARY");
        console.log("========================================\n");

        console.log("Owner:", owner);
        console.log("Fee Safe:", feeWallet);
        console.log("Production:", production);

        console.log("\n--- Core Infrastructure ---");
        if (!production) { console.log("Test USDR:", testUSDR); } else { console.log("USDC:", USDC); }
        console.log("MinimumERC20 Impl:", address(tokenImpl));
        console.log("Registry (Proxy):", address(registry));
        console.log("  - Implementation:", address(registryImplementation));
        console.log("  - Upgradeable: UUPS Pattern");
        console.log("DividendDistributor:", address(dividendDistributor));

        console.log("\n--- Campaign & Market ---");
        console.log("SingleRoundCampaign:", address(singleRoundCampaign));
        console.log("MultiRoundCampaign:", address(multiRoundCampaign));
        console.log("CampaignAdmin:", address(campaignAdmin));
        console.log("CampaignFeeManager:", address(campaignFeeManager));
        console.log("MarketMulticall:", address(market));
        console.log("  - Trading Fee: 2.5%");
        console.log("  - V3: All fees to FeeDistributor");

        console.log("\n--- Oracle System ---");
        console.log("HybridPriceOracle:", address(hybridOracle));
        console.log("OptimisticPriceOracle:", address(optimisticOracle));
        console.log("RiskOracle:", address(riskOracle));
        console.log("JumpRateModel:", address(rateModel));

        console.log("\n--- Tier System ---");
        console.log("VolumeTracker:", address(volumeTracker));
        console.log("TierLogic:", address(tierLogic));

        console.log("\n--- Logic Contracts (V3) ---");
        console.log("InterestLogic:", address(interestLogic));
        console.log("LendingLogic:", address(lendingLogic));
        console.log("StabilityLogic:", address(stabilityLogic));
        console.log("MultiRoundLogic:", address(multiRoundLogic));

        console.log("\n--- Lending System (V3) ---");
        console.log("VaultFactory:", address(vaultFactory));
        console.log("LendingManager:", address(lendingManager));

        console.log("\n--- Fee Distribution (V3) ---");
        console.log("FeeDistributor:", address(feeDistributor));

        console.log("\n--- Contest System ---");
        console.log("Contest:", address(contest));

        console.log("\n--- Keeper System ---");
        console.log("KeeperRegistry:", address(keeperRegistry));

        console.log("\n--- Survey & Redemption ---");
        console.log("BurnRedemption:", address(burnRedemption));
        console.log("SurveySnapshot:", address(surveySnapshot));

        if (adminAddresses.length > 0) {
            console.log("\n=== Admin Screeners Configured ===");
            for (uint256 i = 0; i < adminAddresses.length; i++) {
                console.log("  -", adminAddresses[i]);
            }
            console.log("These addresses can approve campaigns via CampaignAdmin.setCampaignIdApproval()");
        }

        console.log("\n=== Add to .env ===");
        if (!production) { console.log("TEST_USDR_ADDRESS=", testUSDR); }
        console.log("REGISTRY_ADDRESS=", address(registry));
        console.log("CAMPAIGN_ADDRESS=", address(singleRoundCampaign));
        console.log("MULTI_ROUND_CAMPAIGN_ADDRESS=", address(multiRoundCampaign));
        console.log("CAMPAIGN_ADMIN_ADDRESS=", address(campaignAdmin));
        console.log("CAMPAIGN_FEE_MANAGER_ADDRESS=", address(campaignFeeManager));
        console.log("MARKET_ADDRESS=", address(market));
        console.log("TOKEN_IMPLEMENTATION_ADDRESS=", address(tokenImpl));
        console.log("DIVIDEND_DISTRIBUTOR_ADDRESS=", address(dividendDistributor));
        console.log("HYBRID_ORACLE_ADDRESS=", address(hybridOracle));
        console.log("OPTIMISTIC_ORACLE_ADDRESS=", address(optimisticOracle));
        console.log("RISK_ORACLE_ADDRESS=", address(riskOracle));
        console.log("RATE_MODEL_ADDRESS=", address(rateModel));
        console.log("VOLUME_TRACKER_ADDRESS=", address(volumeTracker));
        console.log("TIER_LOGIC_ADDRESS=", address(tierLogic));
        console.log("INTEREST_LOGIC_ADDRESS=", address(interestLogic));
        console.log("LENDING_LOGIC_ADDRESS=", address(lendingLogic));
        console.log("STABILITY_LOGIC_ADDRESS=", address(stabilityLogic));
        console.log("MULTI_ROUND_LOGIC_ADDRESS=", address(multiRoundLogic));
        console.log("VAULT_FACTORY_ADDRESS=", address(vaultFactory));
        console.log("LENDING_MANAGER_ADDRESS=", address(lendingManager));
        console.log("FEE_DISTRIBUTOR_ADDRESS=", address(feeDistributor));
        console.log("CONTEST_ADDRESS=", address(contest));
        console.log("KEEPER_REGISTRY_ADDRESS=", address(keeperRegistry));
        console.log("BURN_REDEMPTION_ADDRESS=", address(burnRedemption));
        console.log("SURVEY_SNAPSHOT_ADDRESS=", address(surveySnapshot));

        console.log("\n=== Next Steps ===");
        console.log("1. Verify all contracts on the block explorer");
        console.log("2. Run VerifyMultisigSetup.s.sol to confirm the full config");
        console.log("3. Test campaign creation and market trading");
        console.log("4. Test fee distribution via FeeDistributor");
        console.log("5. Test Contest volume tracking and prize distribution");
        console.log("6. Monitor UnifiedVault creation on campaign success");
        console.log("7. Call vault.setMinDepositDuration(1 hours) on each new vault");

        console.log("\n========================================");
        console.log("V3 DEPLOYMENT COMPLETE");
        console.log("========================================\n");
    }
}
