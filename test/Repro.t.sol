
// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "forge-std/Test.sol";
import "../src/Market.sol";
import "../src/Registry.sol";
import "../src/MinimumERC20.sol";
import "../src/FeeDistributor.sol";
import "../src/HybridPriceOracle.sol";
import "../src/RiskOracle.sol";
import "../src/interfaces/ILendingInterfaces.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("Mock USDC", "USDC") {}
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 amount) public { _mint(to, amount); }
}

contract MockToken is ERC20 {
    constructor() ERC20("Mock Token", "TKN") {}
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 amount) public { _mint(to, amount); }
    function burn(uint256 amount) public { _burn(msg.sender, amount); }
}

contract ReproductionTest is Test {
    Registry registry;
    Market market;
    MockUSDC usdc;
    MockToken token;
    FeeDistributor feeDistributor;
    HybridPriceOracle hybridOracle;
    RiskOracle riskOracle;
    
    address owner = address(1);
    address creator = address(2);
    address taker = address(3);
    address feeSafe = address(4);

    function setUp() public {
        vm.startPrank(owner);
        registry = new Registry();
        registry.initialize(owner);
        usdc = new MockUSDC();
        registry.setUsdc(address(usdc));
        registry.setFeeSafe(feeSafe);
        
        market = new Market(owner, address(registry), 250);
        registry.setMarket(address(market));
        registry.setAuthorizedContract(address(market), true);
        
        feeDistributor = new FeeDistributor(owner, address(registry));
        registry.setFeeDistributor(address(feeDistributor));
        registry.setAuthorizedContract(address(feeDistributor), true);
        
        hybridOracle = new HybridPriceOracle(owner);
        hybridOracle.setRegistry(address(registry));
        registry.setHybridPriceOracle(address(hybridOracle));
        hybridOracle.setAuthorizedUpdater(address(market), true);
        
        riskOracle = new RiskOracle(owner, address(registry));
        registry.setRiskOracle(address(riskOracle));
        registry.setAuthorizedContract(address(riskOracle), true);
        
        // Deploy token
        token = new MockToken();
        
        // Register campaign first
        registry.registerCampaign(
            address(token),
            creator,
            address(usdc),
            100_000e6,
            200_000e6,
            1, // OVERAGE_UNLIMITED
            creator,
            block.timestamp,
            block.timestamp + 7 days
        );
        
        // Register market in Registry
        registry.enableMarket(address(token));
        
        market.setTradeFee(250); // 2.5%
        market.setAcceptedPaymentToken(address(usdc), true);
        
        vm.stopPrank();
    }

    function test_fillSellOffer_repro() public {
        uint256 tokenAmount = 700_000_000;
        uint256 pricePerToken = 2_000_000; // 2 USDC
        uint256 totalPrice = 1_400_000_000;
        uint256 fee = 35_000_000;

        // 1. Creator creates sell offer
        token.mint(creator, tokenAmount);
        vm.startPrank(creator);
        token.approve(address(market), tokenAmount);
        market.createSellOffer(address(token), address(usdc), tokenAmount, pricePerToken);
        vm.stopPrank();

        // 2. Taker fills sell offer
        usdc.mint(taker, totalPrice + fee);
        vm.startPrank(taker);
        usdc.approve(address(market), totalPrice + fee);
        
        // The offer ID should be 1
        market.fillSellOffer(1, tokenAmount, address(0));
        vm.stopPrank();
    }
}
