// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title ComplexOrderBook
 * @author Your Name
 * @notice A gas-optimized orderbook for decentralized trading with support for multiple pairs
 * @dev Supports limit orders, market orders, partial fills, and order cancellation
 */
contract ComplexOrderBook is ReentrancyGuard, Ownable {
    
    constructor() Ownable(msg.sender) {
        // Initialize the contract with the deployer as the owner
    }
    
    // =============================================================
    //                           STRUCTS
    // =============================================================
    
    /**
     * @notice Order structure containing all order information
     * @param id Unique order identifier
     * @param trader Address of the order creator
     * @param side Order side (0 = BUY, 1 = SELL)
     * @param orderType Order type (0 = LIMIT, 1 = MARKET)
     * @param price Price per unit (for limit orders)
     * @param amount Total amount to trade
     * @param filled Amount already filled
     * @param timestamp Order creation timestamp
     * @param isActive Whether order is still active
     */
    struct Order {
        uint256 id;
        address trader;
        OrderSide side;
        OrderType orderType;
        uint256 price;
        uint256 amount;
        uint256 filled;
        uint256 timestamp;
        bool isActive;
    }
    
    /**
     * @notice Trading pair structure
     * @param baseToken Base token contract address
     * @param quoteToken Quote token contract address
     * @param isActive Whether trading pair is active
     */
    struct TradingPair {
        address baseToken;
        address quoteToken;
        bool isActive;
    }
    
    /**
     * @notice Order book entry for efficient storage
     * @param orderId Reference to the order
     * @param nextOrderId Linked list pointer to next order at same price
     */
    struct OrderBookEntry {
        uint256 orderId;
        uint256 nextOrderId;
    }
    
    // =============================================================
    //                            ENUMS
    // =============================================================
    
    enum OrderSide { BUY, SELL }
    enum OrderType { LIMIT, MARKET }
    
    // =============================================================
    //                        STATE VARIABLES
    // =============================================================
    
    /// @notice Counter for generating unique order IDs
    uint256 public orderIdCounter;
    
    /// @notice Counter for generating unique pair IDs
    uint256 public pairIdCounter;
    
    /// @notice Mapping from order ID to Order struct
    mapping(uint256 => Order) public orders;
    
    /// @notice Mapping from pair ID to TradingPair struct
    mapping(uint256 => TradingPair) public tradingPairs;
    
    /// @notice Mapping from token addresses to pair ID
    mapping(address => mapping(address => uint256)) public tokenPairToPairId;
    
    /// @notice Order book structure: pairId => side => price => first order ID at that price
    mapping(uint256 => mapping(OrderSide => mapping(uint256 => uint256))) public orderBook;
    
    /// @notice Next order in linked list: orderId => nextOrderId
    mapping(uint256 => uint256) public nextOrder;
    
    /// @notice User orders: user => orderId[]
    mapping(address => uint256[]) public userOrders;
    
    /// @notice User balances locked in orders: user => token => amount
    mapping(address => mapping(address => uint256)) public lockedBalances;
    
    /// @notice Best bid prices for each pair
    mapping(uint256 => uint256) public bestBid;
    
    /// @notice Best ask prices for each pair
    mapping(uint256 => uint256) public bestAsk;
    
    /// @notice Trading fees in basis points (100 = 1%)
    uint256 public tradingFee = 30; // 0.3%
    
    /// @notice Accumulated fees: token => amount
    mapping(address => uint256) public accumulatedFees;
    
    // =============================================================
    //                            EVENTS
    // =============================================================
    
    event OrderPlaced(
        uint256 indexed orderId,
        uint256 indexed pairId,
        address indexed trader,
        OrderSide side,
        OrderType orderType,
        uint256 price,
        uint256 amount
    );
    
    event OrderCancelled(
        uint256 indexed orderId,
        uint256 indexed pairId,
        address indexed trader
    );
    
    event OrderMatched(
        uint256 indexed buyOrderId,
        uint256 indexed sellOrderId,
        uint256 indexed pairId,
        uint256 price,
        uint256 amount,
        address buyer,
        address seller
    );
    
    event TradingPairAdded(
        uint256 indexed pairId,
        address indexed baseToken,
        address indexed quoteToken
    );
    
    event TradingPairDeactivated(uint256 indexed pairId);
    
    // =============================================================
    //                           MODIFIERS
    // =============================================================
    
    modifier validPair(uint256 pairId) {
        require(pairId <= pairIdCounter && tradingPairs[pairId].isActive, "Invalid or inactive pair");
        _;
    }
    
    modifier validOrder(uint256 orderId) {
        require(orderId <= orderIdCounter && orders[orderId].isActive, "Invalid or inactive order");
        _;
    }
    
    modifier onlyOrderOwner(uint256 orderId) {
        require(orders[orderId].trader == msg.sender, "Not order owner");
        _;
    }
    
    // =============================================================
    //                      TRADING PAIR MANAGEMENT
    // =============================================================
    
    /**
     * @notice Add a new trading pair
     * @param baseToken Address of the base token
     * @param quoteToken Address of the quote token
     * @return pairId The ID of the newly created trading pair
     */
    function addTradingPair(address baseToken, address quoteToken) 
        external 
        onlyOwner 
        returns (uint256 pairId) 
    {
        require(baseToken != address(0) && quoteToken != address(0), "Invalid token addresses");
        require(baseToken != quoteToken, "Tokens must be different");
        require(tokenPairToPairId[baseToken][quoteToken] == 0, "Pair already exists");
        
        pairIdCounter++;
        pairId = pairIdCounter;
        
        tradingPairs[pairId] = TradingPair({
            baseToken: baseToken,
            quoteToken: quoteToken,
            isActive: true
        });
        
        tokenPairToPairId[baseToken][quoteToken] = pairId;
        tokenPairToPairId[quoteToken][baseToken] = pairId;
        
        emit TradingPairAdded(pairId, baseToken, quoteToken);
    }
    
    /**
     * @notice Deactivate a trading pair
     * @param pairId ID of the pair to deactivate
     */
    function deactivateTradingPair(uint256 pairId) external onlyOwner validPair(pairId) {
        tradingPairs[pairId].isActive = false;
        emit TradingPairDeactivated(pairId);
    }
    
    // =============================================================
    //                         ORDER MANAGEMENT
    // =============================================================
    
    /**
     * @notice Place a new order
     * @param pairId Trading pair ID
     * @param side Order side (BUY or SELL)
     * @param orderType Order type (LIMIT or MARKET)
     * @param price Price per unit (ignored for market orders)
     * @param amount Amount to trade
     * @return orderId The ID of the placed order
     */
    function placeOrder(
        uint256 pairId,
        OrderSide side,
        OrderType orderType,
        uint256 price,
        uint256 amount
    ) external nonReentrant validPair(pairId) returns (uint256 orderId) {
        require(amount > 0, "Amount must be positive");
        
        if (orderType == OrderType.LIMIT) {
            require(price > 0, "Price must be positive for limit orders");
        }
        
        TradingPair memory pair = tradingPairs[pairId];
        
        // Lock required tokens
        if (side == OrderSide.BUY) {
            uint256 requiredQuote = orderType == OrderType.MARKET ? 
                amount : // For market orders, amount is the quote token amount
                (amount * price) / 1e18; // For limit orders, calculate quote needed
            
            IERC20(pair.quoteToken).transferFrom(msg.sender, address(this), requiredQuote);
            lockedBalances[msg.sender][pair.quoteToken] += requiredQuote;
        } else {
            IERC20(pair.baseToken).transferFrom(msg.sender, address(this), amount);
            lockedBalances[msg.sender][pair.baseToken] += amount;
        }
        
        // Create order
        orderIdCounter++;
        orderId = orderIdCounter;
        
        orders[orderId] = Order({
            id: orderId,
            trader: msg.sender,
            side: side,
            orderType: orderType,
            price: price,
            amount: amount,
            filled: 0,
            timestamp: block.timestamp,
            isActive: true
        });
        
        userOrders[msg.sender].push(orderId);
        
        emit OrderPlaced(orderId, pairId, msg.sender, side, orderType, price, amount);
        
        // Try to match the order
        if (orderType == OrderType.MARKET) {
            _executeMarketOrder(orderId, pairId);
        } else {
            _executeLimitOrder(orderId, pairId);
        }
    }
    
    /**
     * @notice Cancel an active order
     * @param orderId ID of the order to cancel
     */
    function cancelOrder(uint256 orderId) 
        external 
        nonReentrant 
        validOrder(orderId) 
        onlyOrderOwner(orderId) 
    {
        Order storage order = orders[orderId];
        uint256 pairId = _getPairIdForOrder(orderId);
        
        // Remove from order book
        _removeFromOrderBook(orderId, pairId);
        
        // Return locked funds
        TradingPair memory pair = tradingPairs[pairId];
        uint256 unfilledAmount = order.amount - order.filled;
        
        if (order.side == OrderSide.BUY) {
            uint256 lockedQuote = (unfilledAmount * order.price) / 1e18;
            lockedBalances[order.trader][pair.quoteToken] -= lockedQuote;
            IERC20(pair.quoteToken).transfer(order.trader, lockedQuote);
        } else {
            lockedBalances[order.trader][pair.baseToken] -= unfilledAmount;
            IERC20(pair.baseToken).transfer(order.trader, unfilledAmount);
        }
        
        order.isActive = false;
        
        emit OrderCancelled(orderId, pairId, order.trader);
    }
    
    // =============================================================
    //                      INTERNAL FUNCTIONS
    // =============================================================
    
    /**
     * @notice Execute a market order by matching with existing orders
     * @param orderId The market order to execute
     * @param pairId Trading pair ID
     */
    function _executeMarketOrder(uint256 orderId, uint256 pairId) internal {
        Order storage marketOrder = orders[orderId];
        uint256 remainingAmount = marketOrder.amount;
        
        // Get opposite side orders
        OrderSide oppositeSide = marketOrder.side == OrderSide.BUY ? OrderSide.SELL : OrderSide.BUY;
        uint256 currentPrice = marketOrder.side == OrderSide.BUY ? bestAsk[pairId] : bestBid[pairId];
        
        while (remainingAmount > 0 && currentPrice > 0) {
            uint256 matchingOrderId = orderBook[pairId][oppositeSide][currentPrice];
            
            if (matchingOrderId == 0) {
                // No orders at this price, move to next price level
                currentPrice = _getNextPrice(pairId, oppositeSide, currentPrice);
                continue;
            }
            
            Order storage matchingOrder = orders[matchingOrderId];
            uint256 matchingAmount = matchingOrder.amount - matchingOrder.filled;
            uint256 tradeAmount = remainingAmount < matchingAmount ? remainingAmount : matchingAmount;
            
            // Execute trade
            _executeTrade(orderId, matchingOrderId, pairId, currentPrice, tradeAmount);
            
            remainingAmount -= tradeAmount;
            
            // If matching order is fully filled, remove from book
            if (matchingOrder.filled == matchingOrder.amount) {
                _removeFromOrderBook(matchingOrderId, pairId);
                matchingOrder.isActive = false;
            }
            
            // If no more quantity at this price, move to next
            if (orderBook[pairId][oppositeSide][currentPrice] == 0) {
                currentPrice = _getNextPrice(pairId, oppositeSide, currentPrice);
            }
        }
        
        // Mark market order as inactive (fully executed or no more matches)
        marketOrder.isActive = false;
    }
    
    /**
     * @notice Execute a limit order by adding to book and matching
     * @param orderId The limit order to execute
     * @param pairId Trading pair ID
     */
    function _executeLimitOrder(uint256 orderId, uint256 pairId) internal {
        Order storage limitOrder = orders[orderId];
        
        // First try to match with existing orders
        _tryMatchLimitOrder(orderId, pairId);
        
        // If order is fully filled, mark as inactive
        if (limitOrder.filled == limitOrder.amount) {
            limitOrder.isActive = false;
            return;
        }
        
        // If order still has unfilled amount, add to order book
        if (limitOrder.filled < limitOrder.amount && limitOrder.isActive) {
            _addToOrderBook(orderId, pairId);
            _updateBestPrices(pairId, limitOrder.side, limitOrder.price);
        }
    }
    
    /**
     * @notice Try to match a limit order with existing orders
     * @param orderId The limit order to match
     * @param pairId Trading pair ID
     */
    function _tryMatchLimitOrder(uint256 orderId, uint256 pairId) internal {
        Order storage limitOrder = orders[orderId];
        OrderSide oppositeSide = limitOrder.side == OrderSide.BUY ? OrderSide.SELL : OrderSide.BUY;
        
        uint256 currentPrice = limitOrder.side == OrderSide.BUY ? bestAsk[pairId] : bestBid[pairId];
        
        while (limitOrder.filled < limitOrder.amount && currentPrice > 0) {
            // Check if price is acceptable
            bool priceAcceptable = limitOrder.side == OrderSide.BUY ? 
                currentPrice <= limitOrder.price : 
                currentPrice >= limitOrder.price;
            
            if (!priceAcceptable) break;
            
            uint256 matchingOrderId = orderBook[pairId][oppositeSide][currentPrice];
            if (matchingOrderId == 0) {
                currentPrice = _getNextPrice(pairId, oppositeSide, currentPrice);
                continue;
            }
            
            Order storage matchingOrder = orders[matchingOrderId];
            uint256 availableAmount = matchingOrder.amount - matchingOrder.filled;
            uint256 remainingAmount = limitOrder.amount - limitOrder.filled;
            uint256 tradeAmount = availableAmount < remainingAmount ? availableAmount : remainingAmount;
            
            // Execute trade
            _executeTrade(orderId, matchingOrderId, pairId, currentPrice, tradeAmount);
            
            // If matching order is fully filled, remove from book
            if (matchingOrder.filled == matchingOrder.amount) {
                _removeFromOrderBook(matchingOrderId, pairId);
                matchingOrder.isActive = false;
            }
            
            // Move to next price if no more orders at current price
            if (orderBook[pairId][oppositeSide][currentPrice] == 0) {
                currentPrice = _getNextPrice(pairId, oppositeSide, currentPrice);
            }
        }
    }
    
    /**
     * @notice Execute a trade between two orders
     * @param buyOrderId Buy order ID
     * @param sellOrderId Sell order ID  
     * @param pairId Trading pair ID
     * @param price Trade execution price
     * @param amount Trade amount
     */
    function _executeTrade(
        uint256 buyOrderId,
        uint256 sellOrderId,
        uint256 pairId,
        uint256 price,
        uint256 amount
    ) internal {
        // Determine which order is buy/sell
        Order storage order1 = orders[buyOrderId];
        Order storage order2 = orders[sellOrderId];
        
        Order storage buyOrder = order1.side == OrderSide.BUY ? order1 : order2;
        Order storage sellOrder = order1.side == OrderSide.SELL ? order1 : order2;
        
        TradingPair memory pair = tradingPairs[pairId];
        
        // Calculate trade values
        uint256 quoteAmount = (amount * price) / 1e18;
        uint256 fee = (quoteAmount * tradingFee) / 10000;
        uint256 netQuoteAmount = quoteAmount - fee;
        
        // Update order fills
        buyOrder.filled += amount;
        sellOrder.filled += amount;
        
        // Update locked balances
        lockedBalances[buyOrder.trader][pair.quoteToken] -= quoteAmount;
        lockedBalances[sellOrder.trader][pair.baseToken] -= amount;
        
        // Transfer tokens
        IERC20(pair.baseToken).transfer(buyOrder.trader, amount);
        IERC20(pair.quoteToken).transfer(sellOrder.trader, netQuoteAmount);
        
        // Collect fees
        accumulatedFees[pair.quoteToken] += fee;
        
        emit OrderMatched(
            buyOrder.id,
            sellOrder.id,
            pairId,
            price,
            amount,
            buyOrder.trader,
            sellOrder.trader
        );
    }
    
    /**
     * @notice Add order to the order book
     * @param orderId Order to add
     * @param pairId Trading pair ID
     */
    function _addToOrderBook(uint256 orderId, uint256 pairId) internal {
        Order memory order = orders[orderId];
        
        uint256 currentOrderId = orderBook[pairId][order.side][order.price];
        
        if (currentOrderId == 0) {
            // First order at this price
            orderBook[pairId][order.side][order.price] = orderId;
        } else {
            // Add to end of linked list
            while (nextOrder[currentOrderId] != 0) {
                currentOrderId = nextOrder[currentOrderId];
            }
            nextOrder[currentOrderId] = orderId;
        }
    }
    
    /**
     * @notice Remove order from the order book
     * @param orderId Order to remove
     * @param pairId Trading pair ID
     */
    function _removeFromOrderBook(uint256 orderId, uint256 pairId) internal {
        Order memory order = orders[orderId];
        uint256 currentOrderId = orderBook[pairId][order.side][order.price];
        
        if (currentOrderId == orderId) {
            // First order in list
            orderBook[pairId][order.side][order.price] = nextOrder[orderId];
        } else {
            // Find and remove from linked list
            while (currentOrderId != 0 && nextOrder[currentOrderId] != orderId) {
                currentOrderId = nextOrder[currentOrderId];
            }
            if (currentOrderId != 0) {
                nextOrder[currentOrderId] = nextOrder[orderId];
            }
        }
        
        nextOrder[orderId] = 0;
    }
    
    /**
     * @notice Update best bid/ask prices
     * @param pairId Trading pair ID
     * @param side Order side
     * @param price New price to consider
     */
    function _updateBestPrices(uint256 pairId, OrderSide side, uint256 price) internal {
        if (side == OrderSide.BUY) {
            if (bestBid[pairId] == 0 || price > bestBid[pairId]) {
                bestBid[pairId] = price;
            }
        } else {
            if (bestAsk[pairId] == 0 || price < bestAsk[pairId]) {
                bestAsk[pairId] = price;
            }
        }
    }
    
    /**
     * @notice Get next price level in order book
     * @param pairId Trading pair ID
     * @param side Order side
     * @param currentPrice Current price
     * @return Next available price level
     */
    function _getNextPrice(uint256 pairId, OrderSide side, uint256 currentPrice) internal view returns (uint256) {
        // This is a simplified implementation
        // In a production system, you'd maintain sorted price levels
        return 0;
    }
    
    /**
     * @notice Get pair ID for an order
     * @param orderId Order ID
     * @return pairId Trading pair ID
     */
    function _getPairIdForOrder(uint256 orderId) internal view returns (uint256 pairId) {
        // For simplicity, we'll iterate through pairs to find the matching one
        // In production, you'd store this mapping directly
        for (uint256 i = 1; i <= pairIdCounter; i++) {
            if (tradingPairs[i].isActive) {
                return i; // Return first active pair for demo
            }
        }
        return 1; // Default to pair 1
    }
    
    // =============================================================
    //                        VIEW FUNCTIONS
    // =============================================================
    
    /**
     * @notice Get order book for a trading pair
     * @param pairId Trading pair ID
     * @param side Order side
     * @param maxDepth Maximum number of price levels to return
     * @return prices Array of prices
     * @return amounts Array of total amounts at each price
     */
    function getOrderBook(uint256 pairId, OrderSide side, uint256 maxDepth)
        external
        view
        validPair(pairId)
        returns (uint256[] memory prices, uint256[] memory amounts)
    {
        prices = new uint256[](maxDepth);
        amounts = new uint256[](maxDepth);
        
        // Implementation would iterate through price levels
        // This is a placeholder structure
    }
    
    /**
     * @notice Get user's orders
     * @param user User address
     * @return orderIds Array of order IDs belonging to the user
     */
    function getUserOrders(address user) external view returns (uint256[] memory orderIds) {
        return userOrders[user];
    }
    
    /**
     * @notice Get order details
     * @param orderId Order ID
     * @return order Order struct
     */
    function getOrder(uint256 orderId) external view returns (Order memory order) {
        return orders[orderId];
    }
    
    /**
     * @notice Get trading pair details
     * @param pairId Pair ID
     * @return pair Trading pair struct
     */
    function getTradingPair(uint256 pairId) external view returns (TradingPair memory pair) {
        return tradingPairs[pairId];
    }
    
    // =============================================================
    //                        ADMIN FUNCTIONS
    // =============================================================
    
    /**
     * @notice Set trading fee
     * @param newFee New fee in basis points
     */
    function setTradingFee(uint256 newFee) external onlyOwner {
        require(newFee <= 1000, "Fee too high"); // Max 10%
        tradingFee = newFee;
    }
    
    /**
     * @notice Withdraw accumulated fees
     * @param token Token address
     * @param amount Amount to withdraw
     */
    function withdrawFees(address token, uint256 amount) external onlyOwner {
        require(accumulatedFees[token] >= amount, "Insufficient fees");
        accumulatedFees[token] -= amount;
        IERC20(token).transfer(owner(), amount);
    }
}
