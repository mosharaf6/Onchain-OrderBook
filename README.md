# On-Chain Order Book

A sophisticated, gas-optimized decentralized order book implementation in Solidity that supports multiple trading pairs, limit/market orders, partial fills, and order cancellation.
This code was written for the purpose of learning about On-chain OrderBooks 

## Features

### Core Functionality
- **Multiple Trading Pairs**: Support for any ERC20 token pairs
- **Order Types**: Limit orders and market orders
- **Order Management**: Place, cancel, and match orders
- **Partial Fills**: Orders can be partially filled across multiple trades
- **Gas Optimization**: Efficient data structures and minimal storage writes

### Security Features
- **Reentrancy Protection**: Uses OpenZeppelin's ReentrancyGuard
- **Access Control**: Owner-only functions for critical operations
- **Input Validation**: Comprehensive validation of all inputs
- **Safe Math**: Built-in overflow protection with Solidity 0.8+

### Trading Features
- **Order Matching**: Automatic matching of compatible orders
- **Price-Time Priority**: Orders matched by price, then time
- **Trading Fees**: Configurable trading fees with fee collection
- **Balance Management**: Proper escrow and settlement of assets

## Architecture

### Data Structures

#### Order Struct
```solidity
struct Order {
    uint256 id;           // Unique order identifier
    address trader;       // Order creator
    OrderSide side;       // BUY or SELL
    OrderType orderType;  // LIMIT or MARKET
    uint256 price;        // Price per unit
    uint256 amount;       // Total amount to trade
    uint256 filled;       // Amount already filled
    uint256 timestamp;    // Creation timestamp
    bool isActive;        // Order status
}
```

### Key Components

1. **Order Book Management**: Linked list structure for efficient order storage
2. **Matching Engine**: Automatic order matching with partial fills
3. **Balance Tracking**: Locked balances and fee management
4. **Price Discovery**: Best bid/ask price tracking

## Usage

### Build

```shell
$ forge build
```

### Test

```shell
$ forge test
```

### Deploy

```shell
$ forge script script/Counter.s.sol --rpc-url <your_rpc_url> --private-key <your_private_key>
```

## Testing

The project includes comprehensive tests covering:
- Trading pair management
- Order placement and cancellation
- Order matching and partial fills
- Access control and security

## License

UNLICENSED 
