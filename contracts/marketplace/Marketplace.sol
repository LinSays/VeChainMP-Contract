// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0 <0.9.0;

import "./IMarketplace.sol";

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@openzeppelin/contracts/interfaces/IERC2981.sol";

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Counters.sol";

contract Marketplace is
	IMarketplace,
	Ownable,
	IERC721Receiver,
	ReentrancyGuard
{
	using Counters for Counters.Counter;

	// Market item counter
	Counters.Counter private _itemCounter;

	// NFT contract address for MP V1: ExoWorlds's contract address
	address private _assetContract;

	// The max bps of the contract. 10000 == 100 %
	uint96 private constant MAX_BPS = 10000;

	// Active listing MP items
	MarketItem[] private _items;

	// Whether listing is restricted by owner.
	bool public restrictedOwnerOnly;

	// Increase `endTime` of auction when new winning bid coming after closed the auction ~5 minutes ago.
	uint64 public timeBuffer = 5 minutes;

	// The minimum increase precent required from the previous winning bid. Default: 5%.
	uint96 public bidBufferBps = 500;

	// Mapping from MP `itemId` to index in listing array
	mapping(uint256 => uint256) private _allItemsIndex;

	// Mapping from MP `tokenId` to index in listing array
	mapping(uint256 => uint256) private _allTokensIndex;

	// Mapping from `tokenId` to offeror address => offer info on a direct listing.
	mapping(uint256 => mapping(address => Offer)) private _offers;

	// Mapping from `tokenId` to current winning bid info in an auction.
	mapping(uint256 => Offer) private _winningBid;

	/// @dev Modifier used internally to accept only new offer.
	modifier onlyNewOffer(uint256 _tokenId, address _offeror) {
		Offer memory targetOffer = _offers[_tokenId][_offeror];
		require(
			targetOffer.offeror == address(0),
			"Marketplace: offer already exists, cancel offer first"
		);
		_;
	}

	/// @dev Modifier used internally to throws if called by any account other than the owner.
	modifier onlyOwnerWhenRestricted() {
		require(
			!restrictedOwnerOnly || owner() == _msgSender(),
			"Marketplace: caller must be owner"
		);
		_;
	}

	constructor() {}

	/// @dev Lets the contract accept VET.
	receive() external payable {}

	/// @inheritdoc	IMarketplace
	function createDirectSaleItem(uint256 _tokenId, uint256 _price)
		external
		override
		onlyOwnerWhenRestricted
	{
		MarketItemParameters memory newItemParams = MarketItemParameters({
			tokenId: _tokenId,
			startTime: 0,
			secondsUntilEndTime: 0,
			reserveTokenPrice: 0,
			buyoutTokenPrice: _price,
			listingType: ListingType.Direct
		});
		createMarketItem(newItemParams);
	}

	/// @inheritdoc	IMarketplace
	function updateMarketItem(
		uint256 _tokenId,
		uint256 _reserveTokenPrice,
		uint256 _buyoutTokenPrice,
		uint256 _startTime,
		uint256 _secondsUntilEndTime
	) external override {
		uint256 index = _allTokensIndex[_tokenId];
		require(index > 0, "Marketplace: non exist marketplace item");
		require(
			_items[index - 1].tokenOwner == _msgSender(),
			"Marketplace: caller is not listing creator"
		);

		MarketItem memory targetItem = _items[index - 1];
		bool isAuction = targetItem.listingType == ListingType.Auction;

		// Can only edit auction listing before it starts.
		if (isAuction) {
			require(
				block.timestamp < targetItem.startTime,
				"Marketplace: auction has already started"
			);
			require(
				_buyoutTokenPrice >= _reserveTokenPrice,
				"Marketplace: reserve price exceeds buyout price"
			);
		}

		uint256 newStartTime = _startTime == 0 ? targetItem.startTime : _startTime;
		_items[index - 1] = MarketItem({
			itemId: targetItem.itemId,
			tokenOwner: targetItem.tokenOwner,
			tokenId: _tokenId,
			startTime: newStartTime,
			endTime: _secondsUntilEndTime == 0
				? targetItem.endTime
				: newStartTime + _secondsUntilEndTime,
			reserveTokenPrice: _reserveTokenPrice,
			buyoutTokenPrice: _buyoutTokenPrice,
			listingType: targetItem.listingType
		});

		emit UpdateMarketItem(
			targetItem.itemId,
			targetItem.tokenId,
			targetItem.tokenOwner,
			_items[index - 1]
		);
	}

	/// @inheritdoc IMarketplace
	function updateDirectSaleItem(uint256 _tokenId, uint256 _price)
		external
		override
	{
		uint256 index = _allTokensIndex[_tokenId];
		require(index > 0, "Marketplace: non exist marketplace item");
		require(
			_items[index - 1].tokenOwner == _msgSender(),
			"Marketplace: caller is not listing creator"
		);

		MarketItem memory targetItem = _items[index - 1];

		_items[index - 1] = MarketItem({
			itemId: targetItem.itemId,
			tokenOwner: targetItem.tokenOwner,
			tokenId: _tokenId,
			startTime: 0,
			endTime: 0,
			reserveTokenPrice: 0,
			buyoutTokenPrice: _price,
			listingType: targetItem.listingType
		});

		emit UpdateMarketItem(
			targetItem.itemId,
			_tokenId,
			targetItem.tokenOwner,
			_items[index - 1]
		);
	}

	/// @inheritdoc IMarketplace
	function removeDirectSaleItem(uint256 _tokenId) external override {
		uint256 index = _allTokensIndex[_tokenId];
		require(index > 0, "Marketplace: non exist marketplace item");

		MarketItem memory item = _items[index - 1];
		require(
			_msgSender() == item.tokenOwner || _msgSender() == owner(),
			"Marketplace: Caller is neither admin nor token owner"
		);

		_removeItemFromAllItemsEnumeration(_tokenId);
	}

	/// @inheritdoc IMarketplace
	function buy(uint256 _tokenId) external payable override nonReentrant {
		MarketItem memory targetItem = getItemByTokenId(_tokenId);
		address buyer = _msgSender();
		require(
			buyer != targetItem.tokenOwner,
			"Marketplace: you cannot buy yourself"
		);
		// Check whether the settled total price
		require(
			msg.value == targetItem.buyoutTokenPrice,
			"Marketplace: invalid price"
		);

		executeSale(targetItem, buyer, targetItem.buyoutTokenPrice);
	}

	/// @inheritdoc IMarketplace
	function offer(uint256 _tokenId) external payable override nonReentrant {
		MarketItem memory targetItem = getItemByTokenId(_tokenId);
		require(
			_msgSender() != targetItem.tokenOwner,
			"Marketplace: caller cannot be listing creator"
		);
		require(
			block.timestamp > targetItem.startTime,
			"Marketplace: inactive item"
		);
		uint256 offerPrice = msg.value;
		require(offerPrice > 0, "Marketplace: invalid offer price");

		Offer memory newOffer = Offer({
			offeror: _msgSender(),
			tokenId: targetItem.tokenId,
			offerPrice: offerPrice
		});

		if (targetItem.listingType == ListingType.Auction) {
			placeBid(targetItem, newOffer);
		} else if (targetItem.listingType == ListingType.Direct) {
			placeOffer(targetItem, newOffer);
		}
	}

	/// @inheritdoc IMarketplace
	function acceptOffer(uint256 _tokenId, address _offeror)
		external
		override
		nonReentrant
	{
		uint256 index = _allTokensIndex[_tokenId];
		require(index > 0, "Marketplace: non exist marketplace item");
		require(
			_items[index - 1].tokenOwner == _msgSender(),
			"Marketplace: caller is not listing creator"
		);
		MarketItem memory targetItem = _items[index - 1];

		Offer memory targetOffer = _offers[_tokenId][_offeror];

		require(
			targetOffer.offeror != address(0) && targetOffer.offerPrice > 0,
			"Marketplace: invalid offeror"
		);

		delete _offers[_tokenId][_offeror];

		executeSale(targetItem, _offeror, targetOffer.offerPrice);
	}

	/// @inheritdoc IMarketplace
	function cancelOffer(uint256 _tokenId) external override nonReentrant {
		address offeror = _msgSender();
		Offer memory targetOffer = _offers[_tokenId][offeror];
		require(
			targetOffer.offeror != address(0) && targetOffer.offerPrice > 0,
			"Marketplace: invalid offer"
		);
		transferCurrency(offeror, targetOffer.offerPrice);
		delete _offers[_tokenId][offeror];
	}

	/// @inheritdoc IMarketplace
	function closeAuction(uint256 _tokenId)
		external
		override
		onlyOwner
		nonReentrant
	{
		MarketItem memory targetItem = getItemByTokenId(_tokenId);

		require(
			targetItem.listingType == ListingType.Auction,
			"Marketplace: not an auction"
		);

		Offer memory targetBid = _winningBid[_tokenId];

		bool toCancel = targetItem.startTime > block.timestamp ||
			targetBid.offeror == address(0);

		if (toCancel) {
			_cancelAuction(targetItem);
		} else {
			payout(targetBid.offerPrice, targetItem);
			_closeAuctionForBidder(targetItem, targetBid);
		}
	}

	/// @dev Sets `_assetContract` address for our collection in MP V1
	function setAssetAddress(address assetContract_) external onlyOwner {
		_assetContract = assetContract_;
	}

	/// @dev Update auction buffers - timeBuffer, and increase bid buffer BPS
	function setAuctionBuffers(uint64 _timeBuffer, uint96 _bidBufferBps)
		external
		onlyOwner
	{
		require(_bidBufferBps < MAX_BPS, "Marketplace: invalid BPS");

		timeBuffer = _timeBuffer;
		bidBufferBps = _bidBufferBps;

		emit AuctionBuffersUpdated(_timeBuffer, _bidBufferBps);
	}

	/// @dev Owner can restrict listing.
	function setRestrictedOwnerOnly(bool restricted) external onlyOwner {
		restrictedOwnerOnly = restricted;
		emit ListingRestricted(restricted);
	}

	/// @dev Gets active listing - `_items`
	function getActiveItems() external view returns (MarketItem[] memory) {
		return _items;
	}

	/// @dev Gets active listing count
	function getActiveItemsCount() external view returns (uint256) {
		return _items.length;
	}

	/// @dev Gets an offer with `_tokenId`, `_offeror`
	function getOffer(uint256 _tokenId, address _offeror)
		external
		view
		returns (Offer memory)
	{
		return _offers[_tokenId][_offeror];
	}

	/// @dev Gets an winning bid for `_tokenId`
	function getWinningBid(uint256 _tokenId)
		external
		view
		returns (Offer memory)
	{
		return _winningBid[_tokenId];
	}

	/// @dev Gets current asset contract address for MP V1
	function nftAddress() external view returns (address) {
		return _assetContract;
	}

	/**
	 *   ERC 721 Receiver functions.
	 **/
	function onERC721Received(
		address,
		address,
		uint256,
		bytes calldata
	) external pure override returns (bytes4) {
		return this.onERC721Received.selector;
	}

	/**
	 * @notice Create a market item in MP
	 * @dev Validate NFT ownership and approval of MP, push item to active listing array
	 * Update mapping itemId => array index, token id
	 * @param _params a market item params
	 *
	 * Requirments:
	 *
	 * - If `listingType` is Auction, `secondsUntilEndTime` must be greater than 0.
	 * - NFT must not listed in MP
	 * - `lister` owned NFT and MP must approved
	 * - If `listingType` is Auction, then `reserveTokenPrice` must be smaller than `buyoutTokenPrice`
	 *
	 * Emits a {CreateMarketItem} event
	 */
	function createMarketItem(MarketItemParameters memory _params)
		public
		onlyOwnerWhenRestricted
	{
		require(
			_allTokensIndex[_params.tokenId] == 0,
			"Marketplace: market item already exists"
		);
		require(
			_params.secondsUntilEndTime > 0 ||
				_params.listingType == ListingType.Direct,
			"Marketplace: secondsUntilEndTime must be greater than 0 for auction"
		);

		// Get values to populate `Listing`.
		uint256 itemId = _itemCounter.current();
		address tokenOwner = _msgSender();

		validateOwnershipAndApproval(tokenOwner, _params.tokenId);

		uint256 startTime = _params.startTime < block.timestamp
			? block.timestamp
			: _params.startTime;
		uint256 endTime = _params.listingType == ListingType.Auction
			? startTime + _params.secondsUntilEndTime
			: 0;
		MarketItem memory newItem = MarketItem({
			itemId: itemId,
			tokenOwner: tokenOwner,
			tokenId: _params.tokenId,
			startTime: startTime,
			endTime: endTime,
			reserveTokenPrice: _params.reserveTokenPrice,
			buyoutTokenPrice: _params.buyoutTokenPrice,
			listingType: _params.listingType
		});

		// Tokens listed for sale in an auction are escrowed in Marketplace.
		if (newItem.listingType == ListingType.Auction) {
			require(
				newItem.buyoutTokenPrice >= newItem.reserveTokenPrice,
				"Marketplace: reserve price exceeds buyout price"
			);
			transferMarketItem(tokenOwner, address(this), newItem);
		}
		_items.push(newItem);
		_allItemsIndex[itemId] = _items.length;
		_allTokensIndex[_params.tokenId] = _items.length;
		_itemCounter.increment();

		emit CreateMarketItem(itemId, _params.tokenId, tokenOwner, newItem);
	}

	/// @dev Gets a MP item by MP item id
	function getItemByMarketId(uint256 _itemId)
		public
		view
		returns (MarketItem memory)
	{
		uint256 index = _allItemsIndex[_itemId];
		require(index > 0, "Marketplace: non exist marketplace item");
		MarketItem memory targetItem = _items[index - 1];
		return targetItem;
	}

	/// @dev Gets a MP item by item id
	function getItemByTokenId(uint256 _tokenId)
		public
		view
		returns (MarketItem memory)
	{
		uint256 index = _allTokensIndex[_tokenId];
		require(index > 0, "Marketplace: non exist marketplace item");
		MarketItem memory targetItem = _items[index - 1];
		return targetItem;
	}

	/// @dev Performs a direct listing sale.
	/**
	 * @notice Execute sale for direct sale item
	 * @dev Validate item, payment split and transfer item\
	 *
	 * @param _targetItem Market item to execute sale
	 * @param _buyer buyer address
	 * @param _price buyout price
	 *
	 * Requirements:
	 *
	 * - `listingType` must be direct sale item
	 * - Item must be active
	 * - Total price must be greater than `market cut fee` + `royalty fee`
	 *
	 * Emits a {NewSale} event
	 */
	function executeSale(
		MarketItem memory _targetItem,
		address _buyer,
		uint256 _price
	) internal {
		validateDirectSale(_targetItem);

		payout(_price, _targetItem);
		transferMarketItem(_targetItem.tokenOwner, _buyer, _targetItem);

		_removeItemFromAllItemsEnumeration(_targetItem.tokenId);

		emit NewSale(
			_targetItem.tokenOwner,
			_buyer,
			_targetItem.itemId,
			_targetItem.tokenId,
			_price
		);
	}

	/**
	 * @notice Place an offer to a direct sale item
	 * @dev Create new offer in `_offers` mapping
	 * @param _targetItem target marketplace item
	 * @param _newOffer new offer struct
	 *
	 * Emits a {NewOffer} event
	 */
	function placeOffer(MarketItem memory _targetItem, Offer memory _newOffer)
		internal
		onlyNewOffer(_targetItem.tokenId, _newOffer.offeror)
	{
		_offers[_targetItem.tokenId][_newOffer.offeror] = _newOffer;

		emit NewOffer(
			_newOffer.offeror,
			_targetItem.itemId,
			_targetItem.tokenId,
			_newOffer.offerPrice,
			_targetItem.listingType
		);
	}

	/**
	 * @notice Place a bid to an auction
	 * @dev Update winning bid
	 * Refund previous winning bid amount.
	 * If bid amount is at `buyoutPrice`, then close auction and execute sale
	 * @param _targetItem target auction item
	 * @param _incomingBid new offer(bid) struct
	 *
	 * Requirements:
	 *
	 * - Bid must be winning bid
	 *
	 * Emits a {NewOffer} event
	 */
	function placeBid(MarketItem memory _targetItem, Offer memory _incomingBid)
		internal
	{
		Offer memory currentWinningBid = _winningBid[_targetItem.tokenId];
		uint256 currentOfferPrice = currentWinningBid.offerPrice;
		uint256 incomingOfferPrice = _incomingBid.offerPrice;

		require(
			isNewWinningBid(
				_targetItem.reserveTokenPrice,
				currentOfferPrice,
				incomingOfferPrice
			),
			"Marketplace: not winning bid"
		);

		// Refund VET to previous winning bidder.
		if (currentWinningBid.offeror != address(0) && currentOfferPrice > 0) {
			transferCurrency(currentWinningBid.offeror, currentOfferPrice);
		}

		// Close auction and execute sale if incoming bid amount is at buyout price.
		if (
			_targetItem.buyoutTokenPrice > 0 &&
			incomingOfferPrice >= _targetItem.buyoutTokenPrice
		) {
			payout(incomingOfferPrice, _targetItem);
			_closeAuctionForBidder(_targetItem, _incomingBid);
		} else {
			// Update the winning bid and listing's end time before external contract calls.
			_winningBid[_targetItem.tokenId] = _incomingBid;

			if (_targetItem.endTime - block.timestamp <= timeBuffer) {
				_targetItem.endTime += timeBuffer;
				uint256 index = _allItemsIndex[_targetItem.itemId] - 1;
				_items[index] = _targetItem;
			}

			// Emit a new offer event
			emit NewOffer(
				_incomingBid.offeror,
				_targetItem.itemId,
				_targetItem.tokenId,
				_incomingBid.offerPrice,
				_targetItem.listingType
			);
		}
	}

	/**
	 * @notice Cancel an auction
	 * @dev Refund NFT to `lister` and remove auction from active listing
	 * @param _targetItem a parameter just like in doxygen (must be followed by parameter name)
	 *
	 * Requirements:
	 *
	 * - Only `lister` can cancel an auction.
	 *
	 * Emits a {AuctionClosed} event
	 */
	function _cancelAuction(MarketItem memory _targetItem) internal {
		transferMarketItem(address(this), _targetItem.tokenOwner, _targetItem);
		_removeItemFromAllItemsEnumeration(_targetItem.tokenId);

		emit AuctionClosed(
			_targetItem.itemId,
			_targetItem.tokenId,
			_targetItem.tokenOwner,
			address(0),
			true
		);
	}

	/**
	 * @notice Close an auction for a bidder
	 * @dev Transfer NFT to winning bidder and remove item from active listing
	 * @param _targetItem Auction item
	 * @param winningBid_ Winning bid in an auction
	 *
	 * Emits a {AcutionClosed} event
	 */
	function _closeAuctionForBidder(
		MarketItem memory _targetItem,
		Offer memory winningBid_
	) internal {
		transferMarketItem(address(this), winningBid_.offeror, _targetItem);
		_removeItemFromAllItemsEnumeration(_targetItem.tokenId);

		// Remove winning bid of the auction
		delete _winningBid[_targetItem.tokenId];

		emit AuctionClosed(
			_targetItem.itemId,
			_targetItem.tokenId,
			_targetItem.tokenOwner,
			winningBid_.offeror,
			false
		);
	}

	/// @dev Transfers tokens listed for sale in a direct or auction listing.
	function transferMarketItem(
		address _from,
		address _to,
		MarketItem memory _item
	) internal {
		IERC721(_assetContract).safeTransferFrom(_from, _to, _item.tokenId, "");
	}

	/// @dev Payout stakeholders on sale
	function payout(uint256 _payoutAmount, MarketItem memory _item) internal {
		address payee = _item.tokenOwner;

		uint256 remainder = _payoutAmount;

		try
			IERC2981(_assetContract).royaltyInfo(_item.tokenId, _payoutAmount)
		returns (address royaltyFeeRecipient, uint256 royaltyFeeAmount) {
			if (royaltyFeeAmount > 0) {
				require(
					royaltyFeeAmount <= _payoutAmount,
					"Marketplace: Royalty amount exceed the total price"
				);
				remainder -= royaltyFeeAmount;
				transferCurrency(royaltyFeeRecipient, royaltyFeeAmount);
			}
		} catch {}
		// Distribute price to token owner
		transferCurrency(payee, remainder);
	}

	/// @dev Transfers a given `_amount` of VET to `_to`.
	function transferCurrency(address _to, uint256 _amount) internal {
		if (_amount == 0) {
			return;
		}
		address payable tgt = payable(_to);

		(bool success, ) = tgt.call{ value: _amount }("");
		require(success, "Marketplace: Failed to send VET");
	}

	/// @dev Checks whether an incoming bid should be the new current highest bid.
	function isNewWinningBid(
		uint256 _reservePrice,
		uint256 _currentWinningBidPrice,
		uint256 _incomingBidPrice
	) internal view returns (bool isValidNewBid) {
		isValidNewBid = _currentWinningBidPrice == 0
			? _incomingBidPrice >= _reservePrice
			: (_incomingBidPrice > _currentWinningBidPrice &&
				((_incomingBidPrice - _currentWinningBidPrice) * MAX_BPS) /
					_currentWinningBidPrice >=
				bidBufferBps);
	}

	/// @dev Validates conditions of a direct listing sale.
	function validateDirectSale(MarketItem memory _item) internal view {
		require(
			_item.listingType == ListingType.Direct,
			"Marketplace: invalid listing type"
		);

		// Check if sale is made within the listing window.
		require(
			block.timestamp > _item.startTime,
			"Marketplace: inactive market item"
		);

		// Check if whether token owner owns and has approved token.
		validateOwnershipAndApproval(_item.tokenOwner, _item.tokenId);
	}

	/// @dev Validates that `_tokenOwner` owns and has approved MP to transfer tokens.
	function validateOwnershipAndApproval(address _tokenOwner, uint256 _tokenId)
		internal
		view
	{
		address market = address(this);
		bool isValid = IERC721(_assetContract).ownerOf(_tokenId) == _tokenOwner &&
			(IERC721(_assetContract).getApproved(_tokenId) == market ||
				IERC721(_assetContract).isApprovedForAll(_tokenOwner, market));

		require(isValid, "Marketplace: invalid ownership or approval");
	}

	/**
	 * @dev Private function to remove a token from index tracking structures = `_allItemsIndex`
	 * @param _tokenId uint256 ID of the item to be removed from the market item list
	 */
	function _removeItemFromAllItemsEnumeration(uint256 _tokenId) private {
		uint256 lastItemIndex = _items.length - 1;
		uint256 removeIndex = _allTokensIndex[_tokenId] - 1;

		MarketItem memory removeItem = _items[removeIndex];

		if (removeIndex != lastItemIndex) {
			MarketItem memory lastItem = _items[lastItemIndex];

			_items[removeIndex] = lastItem;
			_allItemsIndex[lastItem.itemId] = removeIndex + 1;
			_allTokensIndex[lastItem.tokenId] = removeIndex + 1;
		}

		delete _allItemsIndex[removeItem.itemId];
		delete _allTokensIndex[_tokenId];
		_items.pop();

		emit RemoveMarketItem(
			removeItem.itemId,
			_tokenId,
			removeItem.tokenOwner,
			removeItem
		);
	}
}
