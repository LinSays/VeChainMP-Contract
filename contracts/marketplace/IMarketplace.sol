// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0 <0.9.0;

/// @title NFT Marketplace interface for ExoWorlds
/// @author Tamer Fouad
interface IMarketplace {
	/// @notice Two types of listings. `Direct`, `Auction`
	enum ListingType {
		Direct,
		Auction
	}

	/// @notice Offer infomation for making an offer or for placing a bid
	/// @param tokenId The token id that received the offer or bid
	/// @param offeror The offeror address
	/// @param offerPrice The price of offer or bid
	struct Offer {
		address offeror;
		uint256 tokenId;
		uint256 offerPrice;
	}

	/// @dev The struct for the parameter of `createMarketItem` function
	/// @param tokenId The token id of the NFT
	/// @param startTime  The unix timestamp of auction start time
	/// @param secondsUntilEndTime The unix time of auction period.
	/// @param reserveTokenPrice The reserve price for auction listing, ignore when direct listing
	/// @param buyoutTokenPrice The token price for direct sale, buyout price for an auction
	/// @param listingType The listing type - Direct | Auction.
	struct MarketItemParameters {
		uint256 tokenId;
		uint256 startTime;
		uint256 secondsUntilEndTime;
		uint256 reserveTokenPrice;
		uint256 buyoutTokenPrice;
		ListingType listingType;
	}

	/// @dev Struct for the marketplace item
	/// @param tokenOwner The token owner address
	/// @param itemId The marketplace item id
	/// @param tokenId The token id of the NFT
	/// @param startTime  The unix timestamp of auction start time
	/// @param endTime The unix timestamp of auction end time
	/// @param reserveTokenPrice The reserve price for auction listing, ignore when direct listing
	/// @param buyoutTokenPrice The token price for direct sale, buyout price for an auction
	/// @param listingType The listing type - Direct | Auction
	struct MarketItem {
		address tokenOwner;
		uint256 itemId;
		uint256 tokenId;
		uint256 startTime;
		uint256 endTime;
		uint256 reserveTokenPrice;
		uint256 buyoutTokenPrice;
		ListingType listingType;
	}

	/// @notice Emitted when a new market item is created
	/// @param itemId The marketplace item id
	/// @param tokenId The token id of market item
	/// @param lister The address of listing creator
	/// @param newItem The struct of new item
	event CreateMarketItem(
		uint256 indexed itemId,
		uint256 indexed tokenId,
		address indexed lister,
		MarketItem newItem
	);

	/// @notice Emitted when a market item is updated.
	/// @param itemId The marketplace item id
	/// @param tokenId The token id of item market item
	/// @param lister The address of the listing creator
	/// @param updatedItem The struct of updated item
	event UpdateMarketItem(
		uint256 indexed itemId,
		uint256 indexed tokenId,
		address indexed lister,
		MarketItem updatedItem
	);

	/// @notice Emitted when a market item is removed.
	/// @param itemId The marketplace item id
	/// @param tokenId The token id of item market item
	/// @param lister The address of the listing creator
	/// @param removeItem The struct of removed item
	event RemoveMarketItem(
		uint256 indexed itemId,
		uint256 indexed tokenId,
		address indexed lister,
		MarketItem removeItem
	);

	/// @dev Emitted when a direct sale item sold
	/// @param seller The address of seller
	/// @param buyer The address of buyer
	/// @param itemId The marketplace item id
	/// @param tokenId The token id of market item
	/// @param buyoutPrice The buyout price
	event NewSale(
		address indexed seller,
		address buyer,
		uint256 indexed itemId,
		uint256 indexed tokenId,
		uint256 buyoutPrice
	);

	/// @dev Emitted when a new offer placed in direct sale or a new bid placed in an auction
	/// @param offeror The address of offeror
	/// @param itemId The marketplace item id
	/// @param tokenId The token id of market item
	/// @param offerPrice The price of an offer or a bid amount
	/// @param listingType The type of listing `Direct`, `Auction`
	event NewOffer(
		address indexed offeror,
		uint256 itemId,
		uint256 indexed tokenId,
		uint256 offerPrice,
		ListingType indexed listingType
	);

	/// @dev Emitted when an auction is closed
	/// @param itemId The marketplace item id
	/// @param tokenId The token id of market item
	/// @param auctionCreator The address of the auction creator
	/// @param winningBidder The address of winner in the auction
	/// @param cancelled The flag of cancelled or not
	event AuctionClosed(
		uint256 itemId,
		uint256 indexed tokenId,
		address indexed auctionCreator,
		address winningBidder,
		bool indexed cancelled
	);

	/// @dev Emitted when the market cut fee
	/// @param newFee The percent for market cut fee
	event MarketFeeUpdate(uint96 newFee);

	/// @dev Emitted when auction buffer time, increaseBps are updated
	/// @param timeBuffer The time for increase time buffer in auction
	/// @param bidBufferBps The percent for the increase of bid amount
	event AuctionBuffersUpdated(uint64 timeBuffer, uint96 bidBufferBps);

	/// @dev Emitted when the `restrictedOwnerOnly` is updated.
	/// @param restricted The flag for the restricted
	event ListingRestricted(bool restricted);

	/// @notice Create a direct sale item in the marketplace
	/// @dev Make a new `MarketItemParameters` param with `_tokenId` and `_price`
	/// , and call `createMarketItem` function
	/// @param _tokenId The token id
	/// @param _price The price for direct sale
	function createDirectSaleItem(uint256 _tokenId, uint256 _price) external;

	/**
	 * @notice Lister can edit market item
	 * @dev Lister edits `reserveTokenPrice`, `buyoutTokenPrice`, `startTime`, `secondsUntilEndTime` of market item
	 *
	 * @param _tokenId The token id to edit
	 * @param _reserveTokenPrice The minimum price for the auction item
	 * @param _buyoutTokenPrice The buyout price for the market item
	 * @param _startTime The unix timestamp of the auction start time
	 * @param _secondsUntilEndTime The auction period time
	 *
	 * Requirements:
	 *
	 * - Only `lister` can edit market item.
	 * - Cannot edit if auction is already started or if invalid `buyoutPrice`
	 *
	 * Emits a {UpdateMarketItem} event
	 */
	function updateMarketItem(
		uint256 _tokenId,
		uint256 _reserveTokenPrice,
		uint256 _buyoutTokenPrice,
		uint256 _startTime,
		uint256 _secondsUntilEndTime
	) external;

	/// @notice Update direct sale item in MP
	/// @dev Update direct sale item with `_tokenId`, `_price`
	/// @param _tokenId The NFT id and uses `assetAddress`. only for MP V1
	/// @param _price The buyout price of NFT
	/// Same requirements as `updateMarketItem`
	/// Emits a {UpdateMarketItem} event
	function updateDirectSaleItem(uint256 _tokenId, uint256 _price) external;

	/// @notice Remove direct sale item from MP
	/// @dev Remove item from active listing array
	/// Update mapping from `itemId` to listing index, `tokenId` to listing index
	/// Requirements:
	/// - Only owner or admin can remove item
	function removeDirectSaleItem(uint256 _tokenId) external;

	/**
	 * @notice Buy a direct sale item
	 * @dev Execute sale:
	 * 1. Split payment
	 * 2. Transfer item from `seller` to `buyer`
	 * 3. Remove item from active listing array
	 * @param _tokenId Token Id
	 *
	 * Requirements:
	 *
	 * - Seller cannot call this function
	 * - Buyer must pay `buyoutTokenPrice` of item
	 * - Market item's `listingType` must be `Direct`
	 *
	 * Emits a {NewSale} event
	 */
	function buy(uint256 _tokenId) external payable;

	/**
	 * @notice Make an offer to the direct sale item or place a bid to the auction
	 * @dev Create an offer, Replace winning bid
	 * @param _tokenId The token id of MP item
	 *
	 * Requirements:
	 *
	 * - MP item must exists
	 * - Caller cannot be the listing creator
	 * - `offerPrice` must be greater than 0.
	 * - Auction must be started.
	 * - Check other requirements in `placeBid` and `placeOffer`
	 */
	function offer(uint256 _tokenId) external payable;

	/**
	 * @notice Listing creator accept an offer in direct sale item
	 * @dev Execut sale: Refer `buy` function
	 *
	 * @param _tokenId The token id of MP item
	 * @param _offeror The address of the offeror
	 *
	 * Requirements:
	 *
	 * - Offer must be valid.
	 */
	function acceptOffer(uint256 _tokenId, address _offeror) external;

	/**
	 * @notice Offeror cancel an offer and claim VET
	 * @param _tokenId The token id of MP item
	 *
	 * Requirements:
	 *
	 * - Offer must be valid
	 */
	function cancelOffer(uint256 _tokenId) external;

	/**
	 * @notice Close an auction
	 * @dev If the auction is not started or no bid, cancel an auction
	 * If the auction has bidder, close an auction with winning bidder
	 * @param _tokenId The token id of MP item
	 *
	 * Requirements:
	 *
	 * - Only admin can call this function
	 * - Offer must be valid
	 */
	function closeAuction(uint256 _tokenId) external;
}
