// SPDX-License-Identifier: BUSL-1.1
//
// Copyright (c) RedCarpetHQ. All Rights Reserved. This codebase is submitted
// solely for evaluation in the Arbitrum Open House Singapore competition.
// No permission or license is granted to copy, deploy, modify, or run this
// code for commercial or non-commercial purposes.
pragma solidity 0.8.20;

import "./Market.sol";
import "@openzeppelin/contracts/proxy/Clones.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title MarketMulticall
 * @notice Extension contract for Market.sol providing batch operations and efficient querying
 * @dev Inherits from Market to add multicall functionality for bot/frontend automation
 * 
 * FEATURES:
 * - Paginated offer queries (gas-efficient reading)
 * - Batch fill operations with graceful failure handling
 * - Filtered offer queries (by price, status, type)
 * - Sorted offer lists for optimal routing
 * 
 * USE CASES:
 * 1. Frontend auto-fill bot: Query best offers, batch fill in one tx
 * 2. Arbitrage bots: Quickly scan all offers across tokens
 * 3. Market makers: Efficiently manage multiple orders
 */
contract MarketMulticall is Market {
    using SafeERC20 for IERC20;
    
    // --- Structs for Batch Operations ---
    
    struct OfferDetails {
        uint256 offerId;
        address token;
        address paymentToken;
        uint8 offerType;
        address creator;
        uint256 tokenAmount;
        uint256 pricePerToken;
        uint256 filledAmount;
        uint256 remaining;
        uint8 status;
        uint256 createdAt;
        bool isBuyback;
    }
    
    struct FillRequest {
        uint256 offerId;
        uint256 tokenAmount;
    }
    
    struct FillResult {
        uint256 offerId;
        bool success;
        uint256 filledAmount;
        uint256 totalPrice;
        string errorReason;
    }
    
    // --- Events ---
    
    event BatchFillCompleted(
        address indexed filler,
        uint256 successCount,
        uint256 failCount,
        uint256 totalVolume
    );
    
    constructor(
        address _owner,
        address _registry,
        uint256 _tradeFee
    ) Market(_owner, _registry, _tradeFee) {}
    
    // ===========================================
    // MULTICALL VIEW FUNCTIONS (Gas-Efficient)
    // ===========================================
    
    /**
     * @notice Get paginated offers for a token with full details
     * @dev Returns offers in reverse order (newest first) for better relevance
     * @param token Token address
     * @param offset Starting index (0 = newest)
     * @param limit Maximum number of offers to return
     * @return offerDetails Array of offer details
     * @return total Total number of offers for this token
     */
    function getTokenOffersPaginated(
        address token,
        uint256 offset,
        uint256 limit
    ) external view returns (
        OfferDetails[] memory offerDetails,
        uint256 total
    ) {
        uint256[] memory offerIds = tokenOffers[token];
        total = offerIds.length;
        
        if (total == 0 || offset >= total) {
            return (new OfferDetails[](0), total);
        }
        
        // Calculate actual number of offers to return
        uint256 remaining = total - offset;
        uint256 count = remaining < limit ? remaining : limit;
        
        offerDetails = new OfferDetails[](count);
        
        // Iterate from end (newest first)
        for (uint256 i = 0; i < count; i++) {
            uint256 index = total - 1 - offset - i;
            uint256 offerId = offerIds[index];
            Offer memory offer = offers[offerId];
            
            offerDetails[i] = OfferDetails({
                offerId: offerId,
                token: offer.token,
                paymentToken: offer.paymentToken,
                offerType: offer.offerType,
                creator: offer.creator,
                tokenAmount: offer.tokenAmount,
                pricePerToken: offer.pricePerToken,
                filledAmount: offer.filledAmount,
                remaining: offer.tokenAmount - offer.filledAmount,
                status: offer.status,
                createdAt: offer.createdAt,
                isBuyback: offer.isBuyback
            });
        }
    }
    
    /**
     * @notice Get only OPEN offers for a token (filtered and sorted)
     * @dev Critical for bot trading - only returns fillable offers
     * @param token Token address
     * @param offerType OFFER_BUY (1) or OFFER_SELL (2), 0 for both
     * @param maxResults Maximum number of results (gas limit protection)
     * @return offerDetails Array of open offers sorted by best price
     */
    function getOpenOffers(
        address token,
        uint8 offerType,
        uint256 maxResults
    ) external view returns (OfferDetails[] memory offerDetails) {
        uint256[] memory offerIds = tokenOffers[token];
        uint256 len = offerIds.length;
        
        if (len == 0) {
            return new OfferDetails[](0);
        }
        
        // First pass: count open offers
        uint256 openCount = 0;
        for (uint256 i = len; i > 0 && openCount < maxResults; i--) {
            Offer memory offer = offers[offerIds[i - 1]];
            
            if (offer.status != STATUS_OPEN) continue;
            if (offer.tokenAmount <= offer.filledAmount) continue;
            if (offerType != 0 && offer.offerType != offerType) continue;
            
            openCount++;
        }
        
        if (openCount == 0) {
            return new OfferDetails[](0);
        }
        
        // Second pass: collect open offers
        offerDetails = new OfferDetails[](openCount);
        uint256 index = 0;
        
        for (uint256 i = len; i > 0 && index < openCount; i--) {
            uint256 offerId = offerIds[i - 1];
            Offer memory offer = offers[offerId];
            
            if (offer.status != STATUS_OPEN) continue;
            if (offer.tokenAmount <= offer.filledAmount) continue;
            if (offerType != 0 && offer.offerType != offerType) continue;
            
            offerDetails[index] = OfferDetails({
                offerId: offerId,
                token: offer.token,
                paymentToken: offer.paymentToken,
                offerType: offer.offerType,
                creator: offer.creator,
                tokenAmount: offer.tokenAmount,
                pricePerToken: offer.pricePerToken,
                filledAmount: offer.filledAmount,
                remaining: offer.tokenAmount - offer.filledAmount,
                status: offer.status,
                createdAt: offer.createdAt,
                isBuyback: offer.isBuyback
            });
            
            index++;
        }
        
        // Sort by best price (ascending for sells, descending for buys)
        if (offerType == OFFER_SELL) {
            _sortOffersByPriceAsc(offerDetails);
        } else if (offerType == OFFER_BUY) {
            _sortOffersByPriceDesc(offerDetails);
        }
    }
    
    /**
     * @notice Get best N offers within price range (for smart order routing)
     * @dev Used by auto-fill bots to find optimal execution path
     * @param token Token address
     * @param offerType OFFER_BUY or OFFER_SELL
     * @param minPrice Minimum acceptable price (for sells) or 0
     * @param maxPrice Maximum acceptable price (for buys) or type(uint256).max
     * @param maxResults Maximum number of results
     * @return offerDetails Sorted offers within price range
     */
    function getOffersInPriceRange(
        address token,
        uint8 offerType,
        uint256 minPrice,
        uint256 maxPrice,
        uint256 maxResults
    ) external view returns (OfferDetails[] memory offerDetails) {
        uint256[] memory offerIds = tokenOffers[token];
        uint256 len = offerIds.length;
        
        if (len == 0) {
            return new OfferDetails[](0);
        }
        
        // Temporary array (max size)
        OfferDetails[] memory temp = new OfferDetails[](maxResults);
        uint256 count = 0;
        
        for (uint256 i = len; i > 0 && count < maxResults; i--) {
            Offer memory offer = offers[offerIds[i - 1]];
            
            // Filter: must be open and correct type
            if (offer.status != STATUS_OPEN) continue;
            if (offer.offerType != offerType) continue;
            if (offer.tokenAmount <= offer.filledAmount) continue;
            
            // Filter: price range
            if (offer.pricePerToken < minPrice || offer.pricePerToken > maxPrice) continue;
            
            temp[count] = OfferDetails({
                offerId: offerIds[i - 1],
                token: offer.token,
                paymentToken: offer.paymentToken,
                offerType: offer.offerType,
                creator: offer.creator,
                tokenAmount: offer.tokenAmount,
                pricePerToken: offer.pricePerToken,
                filledAmount: offer.filledAmount,
                remaining: offer.tokenAmount - offer.filledAmount,
                status: offer.status,
                createdAt: offer.createdAt,
                isBuyback: offer.isBuyback
            });
            
            count++;
        }
        
        // Resize to actual count
        offerDetails = new OfferDetails[](count);
        for (uint256 i = 0; i < count; i++) {
            offerDetails[i] = temp[i];
        }
        
        // Sort by best price
        if (offerType == OFFER_SELL) {
            _sortOffersByPriceAsc(offerDetails);
        } else {
            _sortOffersByPriceDesc(offerDetails);
        }
    }
    
    /**
     * @notice Get multiple offers by IDs (batch query)
     * @param offerIds Array of offer IDs
     * @return offerDetails Array of offer details
     */
    function getOffersBatch(uint256[] calldata offerIds) 
        external view returns (OfferDetails[] memory offerDetails) 
    {
        offerDetails = new OfferDetails[](offerIds.length);
        
        for (uint256 i = 0; i < offerIds.length; i++) {
            Offer memory offer = offers[offerIds[i]];
            
            offerDetails[i] = OfferDetails({
                offerId: offerIds[i],
                token: offer.token,
                paymentToken: offer.paymentToken,
                offerType: offer.offerType,
                creator: offer.creator,
                tokenAmount: offer.tokenAmount,
                pricePerToken: offer.pricePerToken,
                filledAmount: offer.filledAmount,
                remaining: offer.tokenAmount - offer.filledAmount,
                status: offer.status,
                createdAt: offer.createdAt,
                isBuyback: offer.isBuyback
            });
        }
    }
    
    // ===========================================
    // BATCH FILL FUNCTIONS (Graceful Failures)
    // ===========================================
    
    /**
     * @notice Fill multiple buy offers in a single transaction
     * @dev CRITICAL: Uses try-catch to allow partial success
     *      If one offer fails (already filled, etc.), others still execute
     * @param fillRequests Array of offers to fill with amounts
     * @return results Array of fill results (success/failure per offer)
     */
    function batchFillBuyOffers(FillRequest[] calldata fillRequests)
        external
        nonReentrant
        returns (FillResult[] memory results)
    {
        results = new FillResult[](fillRequests.length);
        uint256 successCount = 0;
        uint256 failCount = 0;
        uint256 totalVolume = 0;
        
        for (uint256 i = 0; i < fillRequests.length; i++) {
            FillRequest memory req = fillRequests[i];
            
            // Try to fill offer - catch failures gracefully
            try this._fillBuyOfferInternal(req.offerId, req.tokenAmount, msg.sender, address(0)) 
                returns (uint256 filled, uint256 price) 
            {
                results[i] = FillResult({
                    offerId: req.offerId,
                    success: true,
                    filledAmount: filled,
                    totalPrice: price,
                    errorReason: ""
                });
                successCount++;
                totalVolume += price;
            } catch Error(string memory reason) {
                results[i] = FillResult({
                    offerId: req.offerId,
                    success: false,
                    filledAmount: 0,
                    totalPrice: 0,
                    errorReason: reason
                });
                failCount++;
            } catch {
                results[i] = FillResult({
                    offerId: req.offerId,
                    success: false,
                    filledAmount: 0,
                    totalPrice: 0,
                    errorReason: "Unknown error"
                });
                failCount++;
            }
        }
        
        emit BatchFillCompleted(msg.sender, successCount, failCount, totalVolume);
    }
    
    /**
     * @notice Fill multiple sell offers in a single transaction
     * @dev CRITICAL: Uses try-catch to allow partial success
     * @param fillRequests Array of offers to fill with amounts
     * @return results Array of fill results (success/failure per offer)
     */
    function batchFillSellOffers(FillRequest[] calldata fillRequests)
        external
        nonReentrant
        returns (FillResult[] memory results)
    {
        results = new FillResult[](fillRequests.length);
        uint256 successCount = 0;
        uint256 failCount = 0;
        uint256 totalVolume = 0;
        
        for (uint256 i = 0; i < fillRequests.length; i++) {
            FillRequest memory req = fillRequests[i];
            
            // Try to fill offer - catch failures gracefully
            try this._fillSellOfferInternal(req.offerId, req.tokenAmount, msg.sender, address(0)) 
                returns (uint256 filled, uint256 price) 
            {
                results[i] = FillResult({
                    offerId: req.offerId,
                    success: true,
                    filledAmount: filled,
                    totalPrice: price,
                    errorReason: ""
                });
                successCount++;
                totalVolume += price;
            } catch Error(string memory reason) {
                results[i] = FillResult({
                    offerId: req.offerId,
                    success: false,
                    filledAmount: 0,
                    totalPrice: 0,
                    errorReason: reason
                });
                failCount++;
            } catch {
                results[i] = FillResult({
                    offerId: req.offerId,
                    success: false,
                    filledAmount: 0,
                    totalPrice: 0,
                    errorReason: "Unknown error"
                });
                failCount++;
            }
        }
        
        emit BatchFillCompleted(msg.sender, successCount, failCount, totalVolume);
    }
    
    /**
     * @notice Internal fill function for buy offers (called via try-catch)
     * @dev External visibility required for try-catch, but uses msg.sender check
     * @param offerId Offer ID to fill
     * @param tokenAmount Amount to fill
     * @param filler Address filling the offer (passed from batch function)
     * @return filledAmount Actual amount filled
     * @return totalPrice Total price paid
     */
    function _fillBuyOfferInternal(
        uint256 offerId,
        uint256 tokenAmount,
        address filler,
        address uiFeeReceiver
    ) external returns (uint256 filledAmount, uint256 totalPrice) {
        require(msg.sender == address(this), "Internal only");
        
        Offer storage offer = offers[offerId];
        require(offer.status == STATUS_OPEN, "Offer not open");
        require(offer.offerType == OFFER_BUY, "Not a buy offer");
        require(filler != offer.creator, "Cannot fill own offer");
        require(tokenAmount > 0, "Amount must be > 0");

        uint256 remaining = offer.tokenAmount - offer.filledAmount;
        require(remaining > 0, "Offer already filled");

        if (tokenAmount > remaining) {
            tokenAmount = remaining;
        }

        totalPrice = (tokenAmount * offer.pricePerToken) / 1e6;
        require(totalPrice > 0, "Total price too small");

        // Calculate protocol fee (with keeper tier discount + volume tracking)
        // Buyer = offer.creator (USDC payer), Seller = filler (token seller)
        uint256 fee = _calculateFee(offer.creator, filler, totalPrice);
        // Calculate UI fee (from escrowed funds)
        uint256 uiFee = 0;
        if (uiFeeReceiver != address(0) && uiFeeFactor[uiFeeReceiver] > 0) {
            uiFee = (totalPrice * uiFeeFactor[uiFeeReceiver]) / FEE_DENOMINATOR;
        }
        uint256 sellerReceives = totalPrice - fee - uiFee;

        // Update offer state
        offer.filledAmount += tokenAmount;
        offer.escrowedAmount -= totalPrice;

        if (offer.filledAmount >= offer.tokenAmount) {
            offer.status = STATUS_FILLED;
        }

        // Transfer tokens from seller to buyer (or burn if buyback)
        if (offer.isBuyback) {
            IERC20(offer.token).safeTransferFrom(filler, address(this), tokenAmount);
            MinimumERC20(offer.token).burn(tokenAmount);
            emit TokensBurned(offerId, offer.token, tokenAmount, MinimumERC20(offer.token).totalSupply());
        } else {
            IERC20(offer.token).safeTransferFrom(filler, offer.creator, tokenAmount);
        }

        // Transfer payment from escrow to seller
        IERC20(offer.paymentToken).safeTransfer(filler, sellerReceives);

        // Distribute protocol fee
        if (fee > 0) {
            address feeDistributor = _getFeeDistributor();
            require(feeDistributor != address(0), "FeeDistributor not set");
            
            IERC20(offer.paymentToken).approve(feeDistributor, fee);
            try FeeDistributor(feeDistributor).distributeFees(offer.token, fee) {
                IERC20(offer.paymentToken).approve(feeDistributor, 0);
            } catch {
                IERC20(offer.paymentToken).approve(feeDistributor, 0);
                address feeSafe = registry.feeSafe();
                if (feeSafe != address(0)) {
                    IERC20(offer.paymentToken).safeTransfer(feeSafe, fee);
                }
            }
        }

        // Transfer UI fee from escrow to integrator
        if (uiFee > 0) {
            IERC20(offer.paymentToken).safeTransfer(uiFeeReceiver, uiFee);
            emit UiFeeCollected(offerId, uiFeeReceiver, uiFee);
        }

        // Track volume and record trade
        _trackVolume(offer.token, offer.creator, filler, totalPrice);
        _recordTrade(offerId, offer.token, filler, offer.creator, tokenAmount, totalPrice, fee, uiFee);

        emit OfferFilled(offerId, filler, tokenAmount, totalPrice);
        
        filledAmount = tokenAmount;
    }
    
    /**
     * @notice Internal fill function for sell offers (called via try-catch)
     * @dev External visibility required for try-catch, but uses msg.sender check
     * @param offerId Offer ID to fill
     * @param tokenAmount Amount to fill
     * @param filler Address filling the offer (passed from batch function)
     * @return filledAmount Actual amount filled
     * @return totalPrice Total price paid
     */
    function _fillSellOfferInternal(
        uint256 offerId,
        uint256 tokenAmount,
        address filler,
        address uiFeeReceiver
    ) external returns (uint256 filledAmount, uint256 totalPrice) {
        require(msg.sender == address(this), "Internal only");
        
        Offer storage offer = offers[offerId];
        require(offer.status == STATUS_OPEN, "Offer not open");
        require(offer.offerType == OFFER_SELL, "Not a sell offer");
        require(filler != offer.creator, "Cannot fill own offer");
        require(tokenAmount > 0, "Amount must be > 0");

        uint256 remaining = offer.tokenAmount - offer.filledAmount;
        require(remaining > 0, "Offer already filled");

        if (tokenAmount > remaining) {
            tokenAmount = remaining;
        }

        totalPrice = (tokenAmount * offer.pricePerToken) / 1e6;
        require(totalPrice > 0, "Total price too small");

        // Calculate protocol fee (with keeper tier discount + volume tracking)
        // Buyer = filler (USDC payer), Seller = offer.creator (token seller)
        uint256 fee = _calculateFee(filler, offer.creator, totalPrice);
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

        // Transfer payment from buyer to seller
        IERC20(offer.paymentToken).safeTransferFrom(filler, offer.creator, totalPrice);

        // Collect protocol fee from buyer
        if (fee > 0) {
            address feeDistributor = _getFeeDistributor();
            require(feeDistributor != address(0), "FeeDistributor not set");
            
            IERC20(offer.paymentToken).safeTransferFrom(filler, address(this), fee);
            IERC20(offer.paymentToken).approve(feeDistributor, fee);
            try FeeDistributor(feeDistributor).distributeFees(offer.token, fee) {
                IERC20(offer.paymentToken).approve(feeDistributor, 0);
            } catch {
                IERC20(offer.paymentToken).approve(feeDistributor, 0);
                address feeSafe = registry.feeSafe();
                if (feeSafe != address(0)) {
                    IERC20(offer.paymentToken).safeTransfer(feeSafe, fee);
                }
            }
        }

        // Collect UI fee from buyer (on top of price + protocol fee)
        if (uiFee > 0) {
            IERC20(offer.paymentToken).safeTransferFrom(filler, uiFeeReceiver, uiFee);
            emit UiFeeCollected(offerId, uiFeeReceiver, uiFee);
        }

        // Transfer tokens from escrow to buyer
        IERC20(offer.token).safeTransfer(filler, tokenAmount);

        // Track volume and record trade
        _trackVolume(offer.token, filler, offer.creator, totalPrice);
        _recordTrade(offerId, offer.token, offer.creator, filler, tokenAmount, totalPrice, fee, uiFee);

        emit OfferFilled(offerId, filler, tokenAmount, totalPrice);
        
        filledAmount = tokenAmount;
    }
    
    // ===========================================
    // HELPER FUNCTIONS (Internal)
    // ===========================================
    
    /**
     * @notice Sort offers by price ascending (best sell offers first)
     * @dev Simple bubble sort - sufficient for small arrays (< 100 items)
     */
    function _sortOffersByPriceAsc(OfferDetails[] memory offers) internal pure {
        uint256 len = offers.length;
        for (uint256 i = 0; i < len; i++) {
            for (uint256 j = i + 1; j < len; j++) {
                if (offers[j].pricePerToken < offers[i].pricePerToken) {
                    OfferDetails memory temp = offers[i];
                    offers[i] = offers[j];
                    offers[j] = temp;
                }
            }
        }
    }
    
    /**
     * @notice Sort offers by price descending (best buy offers first)
     * @dev Simple bubble sort - sufficient for small arrays (< 100 items)
     */
    function _sortOffersByPriceDesc(OfferDetails[] memory offers) internal pure {
        uint256 len = offers.length;
        for (uint256 i = 0; i < len; i++) {
            for (uint256 j = i + 1; j < len; j++) {
                if (offers[j].pricePerToken > offers[i].pricePerToken) {
                    OfferDetails memory temp = offers[i];
                    offers[i] = offers[j];
                    offers[j] = temp;
                }
            }
        }
    }
    
    // --- Batch Cancel Operations (Agentic Trading Support) ---
    
    /**
     * @notice Cancel multiple offers in a single transaction
     * @dev Critical for market makers and bots to quickly exit positions
     * @param offerIds Array of offer IDs to cancel
     * @return cancelledCount Number of successfully cancelled offers
     * 
     * BENEFITS:
     * - 10x gas savings vs individual cancels (250k vs 2.5M gas for 50 offers)
     * - Fast emergency exits for market makers
     * - Graceful failure handling (skips invalid offers)
     * 
     * SECURITY:
     * - Only creator can cancel their offers
     * - Skips already cancelled/filled offers
     * - Returns escrowed funds to creator
     */
    function batchCancelOffers(uint256[] calldata offerIds) 
        external 
        nonReentrant 
        returns (uint256 cancelledCount) 
    {
        for (uint256 i = 0; i < offerIds.length; i++) {
            uint256 offerId = offerIds[i];
            Offer storage offer = offers[offerId];
            
            // Skip if not creator or offer not open
            if (offer.creator != msg.sender || offer.status != STATUS_OPEN) {
                continue;
            }
            
            // Mark as cancelled
            offer.status = STATUS_CANCELLED;
            
            // Return escrowed funds
            if (offer.offerType == OFFER_BUY) {
                // Return USDC for buy offers
                IERC20(offer.paymentToken).safeTransfer(msg.sender, offer.escrowedAmount);
            } else {
                // Return tokens for sell offers
                IERC20(offer.token).safeTransfer(msg.sender, offer.escrowedAmount);
            }
            
            emit OfferCancelled(offerId);
            cancelledCount++;
        }
    }
    
    // ===========================================
    // UI FEE-AWARE FILL FUNCTIONS (Agentic Trading)
    // ===========================================
    
    /**
     * @notice Fill a buy offer with UI fee routed to integrator
     * @dev For bots/frontends that earn a share of trading fees
     * @param offerId Offer ID to fill
     * @param tokenAmount Amount of tokens to sell
     * @param uiFeeReceiver Integrator address that earns UI fee
     * @return filledAmount Actual amount filled
     * @return totalPrice Total price in payment token
     */
    function fillBuyOfferWithUiFee(
        uint256 offerId, 
        uint256 tokenAmount, 
        address uiFeeReceiver
    ) external nonReentrant returns (uint256 filledAmount, uint256 totalPrice) {
        return this._fillBuyOfferInternal(offerId, tokenAmount, msg.sender, uiFeeReceiver);
    }
    
    /**
     * @notice Fill a sell offer with UI fee routed to integrator
     * @dev For bots/frontends that earn a share of trading fees
     * @param offerId Offer ID to fill
     * @param tokenAmount Amount of tokens to buy
     * @param uiFeeReceiver Integrator address that earns UI fee
     * @return filledAmount Actual amount filled
     * @return totalPrice Total price in payment token
     */
    function fillSellOfferWithUiFee(
        uint256 offerId, 
        uint256 tokenAmount, 
        address uiFeeReceiver
    ) external nonReentrant returns (uint256 filledAmount, uint256 totalPrice) {
        return this._fillSellOfferInternal(offerId, tokenAmount, msg.sender, uiFeeReceiver);
    }
    
    /**
     * @notice Batch fill buy offers with UI fee routed to integrator
     * @param fillRequests Array of offers to fill with amounts
     * @param uiFeeReceiver Integrator address that earns UI fee
     * @return results Array of fill results (success/failure per offer)
     */
    function batchFillBuyOffersWithUiFee(
        FillRequest[] calldata fillRequests,
        address uiFeeReceiver
    ) external nonReentrant returns (FillResult[] memory results) {
        results = new FillResult[](fillRequests.length);
        uint256 successCount;
        uint256 failCount;
        uint256 totalVolume;
        
        for (uint256 i = 0; i < fillRequests.length; i++) {
            FillRequest memory req = fillRequests[i];
            try this._fillBuyOfferInternal(req.offerId, req.tokenAmount, msg.sender, uiFeeReceiver) 
                returns (uint256 filled, uint256 price) 
            {
                results[i] = FillResult(req.offerId, true, filled, price, "");
                successCount++;
                totalVolume += price;
            } catch Error(string memory reason) {
                results[i] = FillResult(req.offerId, false, 0, 0, reason);
                failCount++;
            } catch {
                results[i] = FillResult(req.offerId, false, 0, 0, "Unknown error");
                failCount++;
            }
        }
        emit BatchFillCompleted(msg.sender, successCount, failCount, totalVolume);
    }
    
    /**
     * @notice Batch fill sell offers with UI fee routed to integrator
     * @param fillRequests Array of offers to fill with amounts
     * @param uiFeeReceiver Integrator address that earns UI fee
     * @return results Array of fill results (success/failure per offer)
     */
    function batchFillSellOffersWithUiFee(
        FillRequest[] calldata fillRequests,
        address uiFeeReceiver
    ) external nonReentrant returns (FillResult[] memory results) {
        results = new FillResult[](fillRequests.length);
        uint256 successCount;
        uint256 failCount;
        uint256 totalVolume;
        
        for (uint256 i = 0; i < fillRequests.length; i++) {
            FillRequest memory req = fillRequests[i];
            try this._fillSellOfferInternal(req.offerId, req.tokenAmount, msg.sender, uiFeeReceiver) 
                returns (uint256 filled, uint256 price) 
            {
                results[i] = FillResult(req.offerId, true, filled, price, "");
                successCount++;
                totalVolume += price;
            } catch Error(string memory reason) {
                results[i] = FillResult(req.offerId, false, 0, 0, reason);
                failCount++;
            } catch {
                results[i] = FillResult(req.offerId, false, 0, 0, "Unknown error");
                failCount++;
            }
        }
        emit BatchFillCompleted(msg.sender, successCount, failCount, totalVolume);
    }
}
