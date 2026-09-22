// SPDX-License-Identifier: BUSL-1.1
//
// Copyright (c) RedCarpetHQ. All Rights Reserved. This codebase is submitted
// solely for evaluation in the Arbitrum Open House Singapore competition.
// No permission or license is granted to copy, deploy, modify, or run this
// code for commercial or non-commercial purposes.
pragma solidity 0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./Registry.sol";
import "./interfaces/IHybridPriceOracle.sol";
import "./interfaces/IContest.sol";
import "./interfaces/ITierLogic.sol";
import "./interfaces/IVolumeTracker.sol";
import "./MinimumERC20.sol";
import "./FeeDistributor.sol";
import "./RiskOracle.sol";

/**
 * @title Market
 * @notice Simplified marketplace for trading campaign tokens
 * @dev Escrow-based marketplace with all fees routed to FeeDistributor
 * 
 * V3 CHANGES:
 * - All fees sent to FeeDistributor (handles 40/40/10/10 split)
 * - Removed complex fee split logic
 * - Removed VaultLedger integration
 * - Added RiskOracle trade recording for wash trading detection
 * 
 * Architecture Reference: /documentation/LENDING_V3_ARCHITECTURE.md
 */
contract Market is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // --- Core Dependencies ---
    Registry public registry;
    
    uint256 public tradeFee; // Fee in basis points (e.g., 250 = 2.5%)
    uint256 public constant FEE_DENOMINATOR = 10000;
    uint256 public constant MIN_TRADE_SIZE = 1e6; // Minimum 1 USDC worth of tokens
    
    // --- Fee Whitelist ---
    mapping(address => bool) public feeWhitelist;
    
    // --- UI/Integrator Fee Share (Agentic Trading) ---
    mapping(address => uint256) public uiFeeFactor; // integrator => fee share bps
    uint256 public constant MAX_UI_FEE_FACTOR = 50; // Max 0.5%
    
    // V3: Removed pendingContestFees - all fees go directly to FeeDistributor
    
    // --- Accepted Payment Tokens ---
    mapping(address => bool) public acceptedPaymentTokens;

    // --- Offer Types ---
    uint8 public constant OFFER_BUY = 1;
    uint8 public constant OFFER_SELL = 2;

    // --- Offer Status ---
    uint8 public constant STATUS_OPEN = 1;
    uint8 public constant STATUS_FILLED = 2;
    uint8 public constant STATUS_CANCELLED = 3;

    struct Offer {
        uint256 offerId;
        address token;
        address paymentToken;
        uint8 offerType;
        address creator;
        uint256 tokenAmount;
        uint256 pricePerToken;
        uint256 filledAmount;
        uint256 escrowedAmount;
        uint8 status;
        uint256 createdAt;
        bool isBuyback;
    }

    struct Trade {
        uint256 tradeId;
        uint256 offerId;
        address token;
        address seller;
        address buyer;
        uint256 tokenAmount;
        uint256 totalPrice;
        uint256 fee;
        uint256 timestamp;
    }

    uint256 public lastOfferId;
    uint256 public lastTradeId;

    mapping(uint256 => Offer) public offers;
    mapping(address => uint256[]) public userOffers;
    mapping(address => uint256[]) public tokenOffers;
    mapping(uint256 => Trade) public trades;

    // --- Events ---
    event OfferCreated(
        uint256 indexed offerId,
        address indexed token,
        address paymentToken,
        uint8 offerType,
        address indexed creator,
        uint256 tokenAmount,
        uint256 pricePerToken,
        bool isBuyback
    );
    event OfferFilled(uint256 indexed offerId, address indexed filler, uint256 amount, uint256 totalPrice);
    event OfferCancelled(uint256 indexed offerId);
    event OfferPriceUpdated(uint256 indexed offerId, uint256 oldPrice, uint256 newPrice);
    event TradeExecuted(
        uint256 indexed tradeId,
        uint256 indexed offerId,
        address indexed token,
        address seller,
        address buyer,
        uint256 tokenAmount,
        uint256 totalPrice,
        uint256 fee,
        uint256 uiFee
    );
    event FeeUpdated(uint256 newFee);
    event FeeWalletUpdated(address newFeeWallet);
    event ContestSet(address indexed contest);
    event ContestWalletSet(address indexed wallet);
    event WhitelistUpdated(address indexed user, bool whitelisted);
    event AllocationFailed(uint256 amount);
    event PaymentTokenUpdated(address indexed token, bool accepted);
    event MarketIntegrationUpdated(address indexed integration);
    event UiFeeFactorUpdated(address indexed integrator, uint256 factor);
    event UiFeeCollected(uint256 indexed tradeId, address indexed integrator, uint256 amount);
    event TokensBurned(uint256 indexed offerId, address indexed token, uint256 amount, uint256 remainingSupply);

    constructor(
        address _owner,
        address _registry,
        uint256 _tradeFee
    ) {
        _transferOwnership(_owner);
        require(_registry != address(0), "Invalid registry");
        require(_tradeFee <= 1000, "Fee too high"); // Max 10%

        registry = Registry(_registry);
        tradeFee = _tradeFee;
    }
    
    // --- Registry Address Helpers ---
    
    function _getFeeDistributor() internal view returns (address) {
        return registry.feeDistributor();
    }
    
    function _getRiskOracle() internal view returns (address) {
        return registry.riskOracle();
    }
    
    function _getContest() internal view returns (address) {
        return registry.contest();
    }

    // --- Admin Functions ---
    
    // V3: All addresses retrieved from Registry

    function setFeeWhitelist(address user, bool whitelisted) external onlyOwner {
        feeWhitelist[user] = whitelisted;
        emit WhitelistUpdated(user, whitelisted);
    }

    function setFeeWhitelistBatch(address[] calldata users, bool whitelisted) external onlyOwner {
        for (uint256 i = 0; i < users.length; i++) {
            feeWhitelist[users[i]] = whitelisted;
            emit WhitelistUpdated(users[i], whitelisted);
        }
    }

    function setTradeFee(uint256 _tradeFee) external onlyOwner {
        require(_tradeFee <= 1000, "Fee too high");
        tradeFee = _tradeFee;
        emit FeeUpdated(_tradeFee);
    }

    function setAcceptedPaymentToken(address _paymentToken, bool accepted) external onlyOwner {
        acceptedPaymentTokens[_paymentToken] = accepted;
        emit PaymentTokenUpdated(_paymentToken, accepted);
    }
    
    // --- UI Fee Self-Service (Agentic Trading) ---
    
    /**
     * @notice Set your UI fee factor as an integrator/bot
     * @dev Self-service: any address can register. Fee is earned on trades routed through you.
     * @param factor Fee in basis points (max 50 = 0.5%)
     */
    function setUiFeeFactor(uint256 factor) external {
        require(factor <= MAX_UI_FEE_FACTOR, "UI fee too high");
        uiFeeFactor[msg.sender] = factor;
        emit UiFeeFactorUpdated(msg.sender, factor);
    }

    // --- Create Offers ---

    function createBuyOffer(
        address token,
        address paymentToken,
        uint256 tokenAmount,
        uint256 pricePerToken,
        bool isBuyback
    ) external nonReentrant {
        require(registry.isMarketOpen(token), "Market not open");
        require(acceptedPaymentTokens[paymentToken], "Payment token not accepted");
        require(tokenAmount > 0, "Amount must be > 0");
        require(pricePerToken > 0, "Price must be > 0");

        uint256 totalCost = (tokenAmount * pricePerToken) / 1e6;
        require(totalCost >= MIN_TRADE_SIZE, "Trade size too small");

        IERC20(paymentToken).safeTransferFrom(msg.sender, address(this), totalCost);

        uint256 offerId = ++lastOfferId;
        offers[offerId] = Offer({
            offerId: offerId,
            token: token,
            paymentToken: paymentToken,
            offerType: OFFER_BUY,
            creator: msg.sender,
            tokenAmount: tokenAmount,
            pricePerToken: pricePerToken,
            filledAmount: 0,
            escrowedAmount: totalCost,
            status: STATUS_OPEN,
            createdAt: block.timestamp,
            isBuyback: isBuyback
        });

        userOffers[msg.sender].push(offerId);
        tokenOffers[token].push(offerId);

        emit OfferCreated(offerId, token, paymentToken, OFFER_BUY, msg.sender, tokenAmount, pricePerToken, isBuyback);
    }

    function createSellOffer(
        address token,
        address paymentToken,
        uint256 tokenAmount,
        uint256 pricePerToken
    ) external nonReentrant {
        require(registry.isMarketOpen(token), "Market not open");
        require(acceptedPaymentTokens[paymentToken], "Payment token not accepted");
        require(tokenAmount > 0, "Amount must be > 0");
        require(pricePerToken > 0, "Price must be > 0");

        uint256 totalValue = (tokenAmount * pricePerToken) / 1e6;
        require(totalValue >= MIN_TRADE_SIZE, "Trade size too small");

        IERC20(token).safeTransferFrom(msg.sender, address(this), tokenAmount);

        uint256 offerId = ++lastOfferId;
        offers[offerId] = Offer({
            offerId: offerId,
            token: token,
            paymentToken: paymentToken,
            offerType: OFFER_SELL,
            creator: msg.sender,
            tokenAmount: tokenAmount,
            pricePerToken: pricePerToken,
            filledAmount: 0,
            escrowedAmount: tokenAmount,
            status: STATUS_OPEN,
            createdAt: block.timestamp,
            isBuyback: false
        });

        userOffers[msg.sender].push(offerId);
        tokenOffers[token].push(offerId);

        emit OfferCreated(offerId, token, paymentToken, OFFER_SELL, msg.sender, tokenAmount, pricePerToken, false);
    }

    // --- Fill Offers ---

    function fillBuyOffer(uint256 offerId, uint256 tokenAmount, address uiFeeReceiver) external nonReentrant {
        Offer storage offer = offers[offerId];
        require(offer.status == STATUS_OPEN, "Offer not open");
        require(offer.offerType == OFFER_BUY, "Not a buy offer");
        require(msg.sender != offer.creator, "Cannot fill own offer");
        require(tokenAmount > 0, "Amount must be > 0");

        uint256 remaining = offer.tokenAmount - offer.filledAmount;
        require(remaining > 0, "Offer already filled");

        if (tokenAmount > remaining) {
            tokenAmount = remaining;
        }

        uint256 totalPrice = (tokenAmount * offer.pricePerToken) / 1e6;
        require(totalPrice > 0, "Total price too small");

        // Calculate fee with keeper tier discount
        // Buyer = offer.creator (maker), Seller = msg.sender (taker)
        uint256 protocolFee = _calculateFee(offer.creator, msg.sender, totalPrice);
        
        // Calculate UI fee
        uint256 uiFee = 0;
        if (uiFeeReceiver != address(0) && uiFeeFactor[uiFeeReceiver] > 0) {
            uiFee = (totalPrice * uiFeeFactor[uiFeeReceiver]) / FEE_DENOMINATOR;
        }
        
        uint256 sellerReceives = totalPrice - protocolFee - uiFee;

        // Update offer state
        offer.filledAmount += tokenAmount;
        offer.escrowedAmount -= totalPrice;

        if (offer.filledAmount >= offer.tokenAmount) {
            offer.status = STATUS_FILLED;
        }

        // Transfer tokens from seller to buyer (or burn if buyback)
        if (offer.isBuyback) {
            IERC20(offer.token).safeTransferFrom(msg.sender, address(this), tokenAmount);
            MinimumERC20(offer.token).burn(tokenAmount);
            emit TokensBurned(offerId, offer.token, tokenAmount, MinimumERC20(offer.token).totalSupply());
        } else {
            IERC20(offer.token).safeTransferFrom(msg.sender, offer.creator, tokenAmount);
        }

        // Transfer payment from escrow to seller
        IERC20(offer.paymentToken).safeTransfer(msg.sender, sellerReceives);

        // Distribute fee to FeeDistributor (from escrowed funds already in contract)
        if (protocolFee > 0) {
            address feeDistributor = _getFeeDistributor();
            require(feeDistributor != address(0), "FeeDistributor not set");
            
            IERC20(offer.paymentToken).approve(feeDistributor, protocolFee);
            try FeeDistributor(feeDistributor).distributeFees(offer.token, protocolFee) {
                IERC20(offer.paymentToken).approve(feeDistributor, 0);
            } catch {
                IERC20(offer.paymentToken).approve(feeDistributor, 0);
                address feeSafe = registry.feeSafe();
                if (feeSafe != address(0)) {
                    IERC20(offer.paymentToken).safeTransfer(feeSafe, protocolFee);
                }
            }
        }

        // Track volume for contest (buyer is offer.creator, seller is msg.sender)
        _trackVolume(offer.token, offer.creator, msg.sender, totalPrice);

        // Record trade FIRST to increment lastTradeId
        _recordTrade(offerId, offer.token, msg.sender, offer.creator, tokenAmount, totalPrice, protocolFee, uiFee);
        
        // Collect UI fee if applicable (emit with actual tradeId)
        if (uiFee > 0) {
            IERC20(offer.paymentToken).safeTransfer(uiFeeReceiver, uiFee);
            emit UiFeeCollected(lastTradeId, uiFeeReceiver, uiFee);
        }

        emit OfferFilled(offerId, msg.sender, tokenAmount, totalPrice);
    }

    function fillSellOffer(uint256 offerId, uint256 tokenAmount, address uiFeeReceiver) external nonReentrant {
        Offer storage offer = offers[offerId];
        require(offer.status == STATUS_OPEN, "Offer not open");
        require(offer.offerType == OFFER_SELL, "Not a sell offer");
        require(msg.sender != offer.creator, "Cannot fill own offer");
        require(tokenAmount > 0, "Amount must be > 0");

        uint256 remaining = offer.tokenAmount - offer.filledAmount;
        require(remaining > 0, "Offer already filled");

        if (tokenAmount > remaining) {
            tokenAmount = remaining;
        }

        uint256 totalPrice = (tokenAmount * offer.pricePerToken) / 1e6;
        require(totalPrice > 0, "Total price too small");

        // Calculate fee with keeper tier discount
        // Buyer = msg.sender (taker), Seller = offer.creator (maker)
        uint256 protocolFee = _calculateFee(msg.sender, offer.creator, totalPrice);

        // Calculate UI fee
        uint256 uiFee = 0;
        if (uiFeeReceiver != address(0) && uiFeeFactor[uiFeeReceiver] > 0) {
            uiFee = (totalPrice * uiFeeFactor[uiFeeReceiver]) / FEE_DENOMINATOR;
        }

        // Update offer state
        offer.filledAmount += tokenAmount;
        offer.escrowedAmount -= tokenAmount;

        if (offer.filledAmount >= offer.tokenAmount) {
            offer.status = STATUS_FILLED;
        }

        // Transfer payment from buyer to seller (full totalPrice)
        IERC20(offer.paymentToken).safeTransferFrom(msg.sender, offer.creator, totalPrice);

        // Collect fees from buyer (on top of totalPrice)
        if (protocolFee > 0 || uiFee > 0) {
            uint256 totalFeesToCollect = protocolFee + uiFee;
            IERC20(offer.paymentToken).safeTransferFrom(msg.sender, address(this), totalFeesToCollect);
            
            if (protocolFee > 0) {
                address feeDistributor = _getFeeDistributor();
                require(feeDistributor != address(0), "FeeDistributor not set");
                
                IERC20(offer.paymentToken).approve(feeDistributor, protocolFee);
                try FeeDistributor(feeDistributor).distributeFees(offer.token, protocolFee) {
                    IERC20(offer.paymentToken).approve(feeDistributor, 0);
                } catch {
                    IERC20(offer.paymentToken).approve(feeDistributor, 0);
                    address feeSafe = registry.feeSafe();
                    if (feeSafe != address(0)) {
                        IERC20(offer.paymentToken).safeTransfer(feeSafe, protocolFee);
                    }
                }
            }

            // Emit UI fee event with actual tradeId (already incremented by _recordTrade above)
            if (uiFee > 0) {
                IERC20(offer.paymentToken).safeTransfer(uiFeeReceiver, uiFee);
                emit UiFeeCollected(lastTradeId, uiFeeReceiver, uiFee);
            }
        }

        // Transfer tokens from escrow to buyer
        IERC20(offer.token).safeTransfer(msg.sender, tokenAmount);

        // Track volume for contest (buyer is msg.sender, seller is offer.creator)
        _trackVolume(offer.token, msg.sender, offer.creator, totalPrice);

        // Record trade
        _recordTrade(offerId, offer.token, offer.creator, msg.sender, tokenAmount, totalPrice, protocolFee, uiFee);

        emit OfferFilled(offerId, msg.sender, tokenAmount, totalPrice);
    }

    // --- Cancel Offer ---

    function cancelOffer(uint256 offerId) external nonReentrant {
        Offer storage offer = offers[offerId];
        require(offer.creator == msg.sender, "Not offer creator");
        require(offer.status == STATUS_OPEN, "Offer not open");

        offer.status = STATUS_CANCELLED;

        if (offer.offerType == OFFER_BUY) {
            IERC20(offer.paymentToken).safeTransfer(msg.sender, offer.escrowedAmount);
        } else {
            IERC20(offer.token).safeTransfer(msg.sender, offer.escrowedAmount);
        }

        emit OfferCancelled(offerId);
    }
    
    // --- Update Offer Price (Agentic Trading Support) ---
    
    /**
     * @notice Update the price of an existing offer without cancelling
     * @dev Allows market makers to adjust prices efficiently (50% gas savings vs cancel+recreate)
     * @param offerId ID of the offer to update
     * @param newPricePerToken New price per token in payment token decimals
     * 
     * BENEFITS:
     * - 50% gas savings (85k vs 170k for cancel+recreate)
     * - Single transaction (faster execution)
     * - Keeps position in order book
     * - Better for high-frequency price adjustments
     * 
     * RESTRICTIONS:
     * - Only creator can update
     * - Only open offers can be updated
     * - Cannot update partially filled offers (must be 0 filled)
     * - For buy offers: adjusts escrowed USDC amount
     */
    function updateOfferPrice(uint256 offerId, uint256 newPricePerToken) 
        external 
        nonReentrant 
    {
        Offer storage offer = offers[offerId];
        require(offer.creator == msg.sender, "Not offer creator");
        require(offer.status == STATUS_OPEN, "Offer not open");
        require(offer.filledAmount == 0, "Cannot update partially filled offer");
        require(newPricePerToken > 0, "Invalid price");
        
        uint256 oldPrice = offer.pricePerToken;
        
        if (offer.offerType == OFFER_BUY) {
            // Adjust escrowed USDC for buy offers
            uint256 oldCost = (offer.tokenAmount * oldPrice) / 1e6;
            uint256 newCost = (offer.tokenAmount * newPricePerToken) / 1e6;
            
            if (newCost > oldCost) {
                // Price increased - collect additional USDC
                uint256 additional = newCost - oldCost;
                IERC20(offer.paymentToken).safeTransferFrom(
                    msg.sender, 
                    address(this), 
                    additional
                );
            } else if (newCost < oldCost) {
                // Price decreased - return excess USDC
                uint256 excess = oldCost - newCost;
                IERC20(offer.paymentToken).safeTransfer(
                    msg.sender, 
                    excess
                );
            }
            
            offer.escrowedAmount = newCost;
        }
        // Note: Sell offers don't need escrow adjustment (tokens already locked)
        
        offer.pricePerToken = newPricePerToken;
        emit OfferPriceUpdated(offerId, oldPrice, newPricePerToken);
    }

    // --- Internal Functions ---

    /**
     * @notice Calculate trading fee with keeper tier discount
     * @dev Buyer (USDC payer) gets tier discount and volume tracking
     * @param buyer Address of the buyer (pays in USDC)
     * @param seller Address of the seller
     * @param totalPrice Total trade price in USDC
     * @return fee Fee amount to charge (in basis points already applied)
     */
    function _calculateFee(
        address buyer,
        address seller,
        uint256 totalPrice
    ) internal returns (uint256 fee) {
        // Check if either party is whitelisted
        if (feeWhitelist[buyer] || feeWhitelist[seller]) {
            return 0; // No fee for whitelisted addresses
        }

        // Calculate base fee
        uint256 baseFee = tradeFee;
        
        // Apply tier discount if applicable (only for buyer who pays in USDC)
        address tierLogic = registry.tierLogic();
        if (tierLogic != address(0)) {
            uint256 buyerDiscount = ITierLogic(tierLogic).getFeeDiscount(buyer);
            
            if (buyerDiscount > 0 && buyerDiscount <= baseFee) {
                baseFee = baseFee - buyerDiscount;
            }
        }
        
        // Track BUYING volume in VolumeTracker (for tier qualification)
        // Note: Volume tracking moved to _trackVolume() to consolidate with Contest tracking
        
        fee = (totalPrice * baseFee) / FEE_DENOMINATOR;
    }

    /**
     * @notice Track volume for VolumeTracker and Contest (called after trade execution)
     * @dev V3: Consolidated volume tracking - VolumeTracker for tiers, Contest for epochs
     * @param token Token address
     * @param buyer Buyer address
     * @param seller Seller address
     * @param totalPrice Total trade price (in USDC, 6 decimals)
     */
    function _trackVolume(address token, address buyer, address seller, uint256 totalPrice) internal {
        bool buyerWhitelisted = feeWhitelist[buyer];
        bool sellerWhitelisted = feeWhitelist[seller];
        
        // Track volume in VolumeTracker (for TierLogic 30-day calculation)
        address volumeTracker = registry.volumeTracker();
        if (volumeTracker != address(0) && !buyerWhitelisted) {
            // Track buyer's volume (for tier qualification)
            try IVolumeTracker(volumeTracker).trackVolume(buyer, totalPrice) {} catch {}
        }
        
        // Track volume in Contest (for 7-day epoch calculation)
        address contest = _getContest();
        if (contest != address(0) && !buyerWhitelisted && !sellerWhitelisted) {
            // Only track if BOTH buyer and seller are NOT whitelisted
            try IContest(contest).addBuyVolume(token, buyer, uint128(totalPrice)) {} catch {}
        }
        
        // V3: Fee deposits handled by FeeDistributor, not here
    }

    /**
     * @notice Record trade and notify oracles
     * @dev V3: Notifies RiskOracle for wash trading detection and HybridPriceOracle for price updates
     */
    function _recordTrade(
        uint256 offerId,
        address token,
        address seller,
        address buyer,
        uint256 tokenAmount,
        uint256 totalPrice,
        uint256 protocolFee,
        uint256 uiFee
    ) internal {
        uint256 tradeId = ++lastTradeId;
        trades[tradeId] = Trade({
            tradeId: tradeId,
            offerId: offerId,
            token: token,
            seller: seller,
            buyer: buyer,
            tokenAmount: tokenAmount,
            totalPrice: totalPrice,
            fee: protocolFee,
            timestamp: block.timestamp
        });
        
        // Note: Field 'fee' in Trade struct currently only stores protocolFee.
        // If needed, the Trade struct should be updated to include uiFee as well.

        Offer memory offer = offers[offerId];
        uint256 pricePerToken = offer.pricePerToken;

        // V3: Notify RiskOracle for wash trading detection
        address riskOracle = _getRiskOracle();
        if (riskOracle != address(0)) {
            try RiskOracle(riskOracle).recordTrade(token, seller, buyer, pricePerToken) {} catch {}
        }
        
        // Notify HybridPriceOracle for price updates
        address priceOracle = registry.hybridPriceOracle();
        if (priceOracle != address(0)) {
            try IHybridPriceOracle(priceOracle).recordTrade(token, pricePerToken, totalPrice) {} catch {}
        }

        emit TradeExecuted(tradeId, offerId, token, seller, buyer, tokenAmount, totalPrice, protocolFee, uiFee);
    }

    // --- View Functions ---
    
    /**
     * @notice Preview the result of filling an offer (view function — no state change)
     * @dev Critical for bot/frontend integration. Simulates fee calculation.
     * @param offerId Offer ID to preview
     * @param tokenAmount Amount of tokens to fill
     * @param filler Address that would fill the offer
     * @param uiFeeReceiver Optional UI fee receiver (address(0) if none)
     * @return actualAmount How much will actually be filled
     * @return totalPrice Total price in payment token
     * @return protocolFee Protocol fee amount
     * @return uiFee UI/integrator fee amount  
     * @return sellerReceives Net amount seller receives
     * @return buyerPays Total buyer pays (price + fees)
     */
    function previewFillOffer(
        uint256 offerId, 
        uint256 tokenAmount, 
        address filler,
        address uiFeeReceiver
    ) external view returns (
        uint256 actualAmount,
        uint256 totalPrice,
        uint256 protocolFee,
        uint256 uiFee,
        uint256 sellerReceives,
        uint256 buyerPays
    ) {
        Offer memory offer = offers[offerId];
        require(offer.status == STATUS_OPEN, "Offer not open");
        
        uint256 remaining = offer.tokenAmount - offer.filledAmount;
        actualAmount = tokenAmount > remaining ? remaining : tokenAmount;
        totalPrice = (actualAmount * offer.pricePerToken) / 1e6;
        
        // Simulate protocol fee (view-safe version)
        protocolFee = _viewCalculateFee(offer.creator, filler, totalPrice);
        
        // Simulate UI fee
        if (uiFeeReceiver != address(0) && uiFeeFactor[uiFeeReceiver] > 0) {
            uiFee = (totalPrice * uiFeeFactor[uiFeeReceiver]) / FEE_DENOMINATOR;
        }
        
        if (offer.offerType == OFFER_BUY) {
            // Buy offer: fees deducted from escrowed payment, seller receives less
            sellerReceives = totalPrice - protocolFee - uiFee;
            buyerPays = totalPrice; // Already escrowed
        } else {
            // Sell offer: buyer pays price + fees on top
            sellerReceives = totalPrice;
            buyerPays = totalPrice + protocolFee + uiFee;
        }
    }
    
    /**
     * @notice View-safe fee calculation (no state changes)
     * @dev Mirrors _calculateFee logic but without keeper volume tracking
     */
    function _viewCalculateFee(
        address buyer,
        address seller,
        uint256 totalPrice
    ) internal view returns (uint256 fee) {
        if (feeWhitelist[buyer] || feeWhitelist[seller]) {
            return 0;
        }
        
        uint256 baseFee = tradeFee;
        
        address tierLogic = registry.tierLogic();
        if (tierLogic != address(0)) {
            uint256 buyerDiscount = ITierLogic(tierLogic).getFeeDiscount(buyer);
            
            if (buyerDiscount > 0 && buyerDiscount <= baseFee) {
                baseFee = baseFee - buyerDiscount;
            }
        }
        
        fee = (totalPrice * baseFee) / FEE_DENOMINATOR;
    }

    function getOffer(uint256 offerId) external view returns (Offer memory) {
        return offers[offerId];
    }

    function getUserOffers(address user) external view returns (uint256[] memory) {
        return userOffers[user];
    }

    function getTokenOffers(address token) external view returns (uint256[] memory) {
        return tokenOffers[token];
    }
    
    function getTokenOffersLength(address token) external view returns (uint256) {
        return tokenOffers[token].length;
    }

    function getTrade(uint256 tradeId) external view returns (Trade memory) {
        return trades[tradeId];
    }

    function isWhitelisted(address user) external view returns (bool) {
        return feeWhitelist[user];
    }
    
    // V3: flushStuckFees removed - fees now handled by FeeDistributor
    
    /**
     * @notice Get market depth for a token (for UnifiedVault supply cap)
     * @dev CRITICAL FIX (M-01): Iterates from END of array (most recent offers) to find active ones
     * @param token Token address
     * @return buyDepth Total USDC in open buy offers
     * @return sellDepth Total token amount in open sell offers
     */
    function getMarketDepth(address token) external view returns (
        uint256 buyDepth,
        uint256 sellDepth
    ) {
        uint256[] memory offerIds = tokenOffers[token];
        uint256 len = offerIds.length;
        
        if (len == 0) return (0, 0);
        
        // CRITICAL FIX (M-01): Iterate from END (most recent) to find active offers
        // This ensures we check the newest offers first, which are more likely to be open
        uint256 checked = 0;
        uint256 maxToCheck = 100; // Limit for gas
        
        for (uint256 i = len; i > 0 && checked < maxToCheck; i--) {
            Offer memory offer = offers[offerIds[i - 1]];
            checked++;
            
            // Only count open offers
            if (offer.status != STATUS_OPEN) continue;
            
            uint256 remaining = offer.tokenAmount - offer.filledAmount;
            if (remaining == 0) continue;
            
            if (offer.offerType == OFFER_BUY) {
                // Buy offer: USDC depth
                uint256 remainingValue = (remaining * offer.pricePerToken) / 1e6;
                buyDepth += remainingValue;
            } else {
                // Sell offer: Token depth
                sellDepth += remaining;
            }
        }
    }
    
    /**
     * @notice Get market depth for multiple tokens (gas efficient)
     * @param tokens Array of token addresses
     * @return buyDepths Array of USDC buy depths
     * @return sellDepths Array of token sell depths
     */
    function getMarketDepthBatch(address[] calldata tokens) 
        external view returns (
            uint256[] memory buyDepths,
            uint256[] memory sellDepths
        ) 
    {
        buyDepths = new uint256[](tokens.length);
        sellDepths = new uint256[](tokens.length);
        
        for (uint i = 0; i < tokens.length; i++) {
            (buyDepths[i], sellDepths[i]) = this.getMarketDepth(tokens[i]);
        }
    }

    // --- Emergency ---

    /**
     * @notice Recover stuck ERC20 tokens
     * @dev SECURITY: Owner is trusted to calculate recoverable amounts off-chain.
     *      DoS FIX: Removed loop through tokenOffers array to prevent gas limit attacks.
     *      Owner should verify off-chain that amount doesn't exceed non-escrowed balance.
     * @param token Token address to recover
     * @param to Recipient address
     * @param amount Amount to recover
     */
    function recoverERC20(address token, address to, uint256 amount) external onlyOwner {
        require(token != address(0) && to != address(0), "Invalid address");
        require(amount > 0, "Zero amount");
        
        // Trust owner to calculate recoverable amount off-chain
        // This avoids DoS via unbounded loop through tokenOffers array
        IERC20(token).safeTransfer(to, amount);
    }
}
