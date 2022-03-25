// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0 <0.9.0;

import "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721EnumerableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721URIStorageUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/common/ERC2981Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/CountersUpgradeable.sol";

/// @title A title that should describe the contract/interface
/// @author Tamer Fouad
/// @notice NFT contract ERC721
/// @dev This is V1 logic contract of ExoWorlds NFT.
/// Implemented Upgradeable, Enumerable, URIStorage, Burnable, Pausable, Royalty feature.
contract PlanetNFT is
	Initializable,
	ERC721EnumerableUpgradeable,
	ERC721URIStorageUpgradeable,
	ERC2981Upgradeable,
	PausableUpgradeable,
	OwnableUpgradeable
{
	using CountersUpgradeable for CountersUpgradeable.Counter;

	CountersUpgradeable.Counter private _tokenPendingIdCounter;

	// NFT collection item supply
	uint256 private MAX_PLANET;

	// Base token URI
	string private _baseTokenURI;

	// Available Tokens for minting
	uint256[] private _availableTokens;

	// Counter for initialization
	uint256 private _initCounter;

	// Address that can call with random seed
	address private _oracleRandom;

	// Pending mint counter array
	uint256[] private _indexPendingMints;

	// Max pending mint count
	uint256 private _maxPendingMintsToProcess;

	// Max mint count for give away
	uint256 private _totalMintsForGiveaway;

	// NFT price for each tier
	uint256[] private TIER_PRICE;

	// Array of Block Numbers for each tier range.
	uint256[] private TIER_BLOCK;

	// Limit the number of mints per tier
	uint8[] private TIER_MINT_LIMIT;

	// Giveaway address
	address private _giveawayAddress;

	// Mapping from address to white list flag
	mapping(address => uint8) private _whitelister;

	// Mapping from pending count to mint request address
	mapping(uint256 => address) private _pendingMint;

	// Mapping from tier number to minted amount of address
	mapping(uint8 => mapping(address => uint8)) private _mintCounter;

	/// @dev Modifier used internally to prevent minting until tokens are fully initialized.
	modifier onlyAfterFullInit() {
		require(
			_isFullyInitialized(),
			"Available tokens not fully initialized yet"
		);
		_;
	}

	/// @dev Modifier used internally to set variables before starting mint.
	modifier onlyBeforeMint() {
		require(totalSupply() == 0, "Minting tokens already started");
		_;
	}

	/// @dev Emitted when number of minting requests are added to pending array.
	event AddPendingMint(
		address indexed minter,
		uint8 indexed amount,
		uint256 pendingId
	);

	/// @dev Emitted when token minted with randomSeed
	event MintedWithRandomNumber(address indexed minter, uint256 randomSeed);

	/// @custom:oz-upgrades-unsafe-allow constructor
	constructor() initializer {}

	function initialize() public initializer {
		__ERC721_init("PLANET", "PLN");
		__ERC721Enumerable_init();
		__ERC721URIStorage_init();
		__ERC2981_init();
		__Pausable_init();
		__Ownable_init();
		// Initialize variables
		_initCounter = 0;
		_maxPendingMintsToProcess = 100;
		MAX_PLANET = 10000;
		TIER_PRICE = [
			20_0000_0000_0000_0000_0000,
			21_0000_0000_0000_0000_0000,
			22_0000_0000_0000_0000_0000,
			23_0000_0000_0000_0000_0000,
			25_0000_0000_0000_0000_0000
		];
		TIER_BLOCK = [
			11381920,
			11407840,
			11390560,
			11416480,
			11399200,
			11425120,
			11407840,
			11433760,
			11416480
		];
		_oracleRandom = address(0);
	}

	/**
	 * @notice Start mint batch with mint amount
	 * @dev Receive VET and add mint request to pending array
	 * @param amount The number of minting
	 *
	 * Requirements:
	 *
	 * - `amount` cannot exceed the total mint.
	 * - `msgSender` must be in any tier.
	 * - If `msgSender` is not giveaway address, correct VET amount must be sent.
	 * - If `msgSender` is giveaway address, `amount` cannot be exceed the limit giveaway mint.
	 * - `msgSender`'s mint limit cannot be exceed the limitation mint in tier.
	 * - Extra VET must be refunded. :)
	 *
	 * Emits a {AddPendingMint} event.
	 */
	function startMintBatch(uint8 amount) external payable onlyAfterFullInit {
		require(
			MAX_PLANET >= amount + _tokenPendingIdCounter.current(),
			"Not enough tokens left to mint"
		);

		if (_giveawayAddress != _msgSender()) {
			uint8 tier_num = getTierNumber(_msgSender());
			require(tier_num > 0, "Not available tier to mint");
			require(
				msg.value >= getPrice() * amount,
				"Amount of VET sent not correct"
			);
			require(
				_mintCounter[tier_num - 1][_msgSender()] + amount <=
					TIER_MINT_LIMIT[tier_num - 1],
				"Overflow maximum mint limitation in tier"
			);

			// Refund extra VET
			address payable tgt = payable(_msgSender());
			(bool success, ) = tgt.call{ value: msg.value - getPrice() * amount }("");
			require(success, "Failed to refund");

			_mintCounter[tier_num - 1][_msgSender()] =
				_mintCounter[tier_num - 1][_msgSender()] +
				amount;
		} else {
			require(_totalMintsForGiveaway > 0, "No mints for giveaway left");
			_totalMintsForGiveaway -= amount;
		}

		uint256 pendingIdCounter = _tokenPendingIdCounter.current();

		emit AddPendingMint(_msgSender(), amount, pendingIdCounter);
		// Add pending list
		for (uint8 i = 0; i < amount; i++) {
			_indexPendingMints.push(pendingIdCounter + i);
			_pendingMint[pendingIdCounter + i] = _msgSender();
			_tokenPendingIdCounter.increment();
		}
	}

	/**
	 * @notice Complete mint batch.
	 * @dev Mint tokens randomly.
	 * Remove tokens from available list and remove request id from pending list.
	 * @param randomSeed The seed number for random minting
	 *
	 * Requirements:
	 *
	 * - `msgSender` must be `_oracleRandom` address.
	 *
	 * Emits a {MintedWithRandomNumber} event.
	 */
	function completeMintBatch(uint256 randomSeed) external {
		require(_oracleRandom == _msgSender(), "No random oracle service");

		uint256[] memory tmp_indexPendingMints = _indexPendingMints;
		for (uint256 i = 0; i < tmp_indexPendingMints.length; i++) {
			address minter = _pendingMint[tmp_indexPendingMints[i]];
			uint256 randomNumber = getRandomNumber(
				_availableTokens.length,
				randomSeed,
				tmp_indexPendingMints.length
			);
			uint256 tokenId = _availableTokens[randomNumber];
			emit MintedWithRandomNumber(minter, randomSeed);

			_safeMint(minter, tokenId);

			_removeTokenFromAvailableList(randomNumber);
			_removeIdFromPendingList(0);
			if (i > _maxPendingMintsToProcess) {
				return;
			}
		}
	}

	/**
	 * @notice Initialize available list for preparing mint
	 * @dev Initialize 200 tokens to create available token array
	 *
	 * Requirements:
	 *
	 * - Tokens must not be initialized yet.
	 */
	function initTokenList() external onlyOwner {
		require(!_isFullyInitialized(), "Tokens are already initialized");
		for (uint256 i = 0; i < 200; i++) {
			_availableTokens.push(_initCounter + i);
		}
		_initCounter += 200;
	}

	/**
	 * @notice Add addresses to whitelist
	 * @dev Explain to a developer any extra details
	 *
	 * @param index a index for whitelist for tier index
	 * @param list address array for insert whitelist
	 *
	 * Requirements:
	 *
	 * - `index` must be valid whitelist.
	 */
	function addWhiteList(uint8 index, address[] memory list) external onlyOwner {
		require(index >= 0 && index < 4, "Invalid whitelist index");
		for (uint256 i = 0; i < list.length; i++) {
			_whitelister[list[i]] = _whitelister[list[i]] | (uint8(1) << index);
		}
	}

	/**
	 * @dev Sets the total amount of NFTs
	 * @param limit new total amount of NFTs
	 *
	 * Requirements:
	 *
	 * - Only owner can call this function.
	 * - Must be called before starting mint.
	 */
	function setMaxLimit(uint256 limit) external onlyOwner onlyBeforeMint {
		MAX_PLANET = limit;
	}

	/**
	 * @dev Sets the giveaway address
	 * @param giveawayAddress address for giveaway
	 */
	function setGiveAwayAddress(address giveawayAddress) external onlyOwner {
		_giveawayAddress = giveawayAddress;
	}

	/**
	 * @dev Sets the total giveaway mints
	 * @param limit limitation of giveaway mints
	 *
	 * Requirements:
	 *
	 * - Only owner can call this function.
	 * - Must be called before starting mint.
	 */
	function setTotalMintsForGiveaway(uint256 limit)
		external
		onlyOwner
		onlyBeforeMint
	{
		_totalMintsForGiveaway = limit;
	}

	/**
	 * @dev Sets the max pending mints
	 * @param maxPendingMintsToProcess max pending mints amount
	 *
	 * Requirements:
	 *
	 * - Only owner can call this function.
	 */
	function setMaxPendingMintsToProcess(uint256 maxPendingMintsToProcess)
		external
		onlyOwner
	{
		_maxPendingMintsToProcess = maxPendingMintsToProcess;
	}

	/**
	 * @dev Sets the address that can request with random seed
	 * @param oracleRandom address for random
	 *
	 * Requirements:
	 *
	 * - Only owner can call this function.
	 */
	function setOracleRandom(address oracleRandom) external onlyOwner {
		_oracleRandom = oracleRandom;
	}

	/**
	 * @dev Sets the block number of tier
	 * @param index tier index
	 * @param tsBlock block number
	 *
	 * Requirements:
	 *
	 * - Only owner can call this function.
	 * - `index` must be valid in tier block array
	 */
	function setBlockLimit(uint8 index, uint256 tsBlock) external onlyOwner {
		require(index >= 0 && index < 9, "Invalied index of tier block");
		TIER_BLOCK[index] = tsBlock;
	}

	/**
	 * @dev Sets the block price of tier
	 * @param index tier index
	 * @param price VET price of NFT in certain tier
	 *
	 * Requirements:
	 *
	 * - Only owner can call this function.
	 * - `index` must be valid in tier price array.
	 */
	function setTierPrice(uint8 index, uint256 price) external onlyOwner {
		require(index >= 0 && index < 5, "Invalied index of tier price");
		TIER_PRICE[index] = price;
	}

	/**
	 * @dev Sets the block number of tier
	 * @param index tier index
	 * @param limit NFT price in tier
	 *
	 * Requirements:
	 *
	 * - Only owner can call this function.
	 * - `index` must be valid in tier price array.
	 */
	function setTierMintLimit(uint8 index, uint8 limit) external onlyOwner {
		require(index >= 0 && index < 5, "Invalied index of tier price");
		TIER_MINT_LIMIT[index] = limit;
	}

	/**
	 * @dev Sets the `_tokenURI` as the tokenURI of `tokenId`
	 *
	 * Requirements:
	 *
	 * - Only owner can call this function.
	 */
	function setTokenURI(uint256 tokenId, string memory _tokenURI)
		external
		onlyOwner
	{
		_setTokenURI(tokenId, _tokenURI);
	}

	/**
	 * @dev Sets the default royalty
	 *
	 * Requirements:
	 *
	 * - Only owner can call this function.
	 */
	function setDefaultRoyalty(address receiver, uint96 feeNumerator)
		external
		onlyOwner
	{
		_setDefaultRoyalty(receiver, feeNumerator);
	}

	/**
	 * @dev Removes default royalty
	 *
	 * Requirements:
	 *
	 * - Only owner can call this function.
	 */
	function deleteDefaultRoyalty() external onlyOwner {
		_deleteDefaultRoyalty();
	}

	/**
	 * @dev Sets the royalty for a specific NFT
	 *
	 * Requirements:
	 *
	 * - Caller must be approved or owner of token.
	 */
	function setTokenRoyalty(
		uint256 tokenId,
		address receiver,
		uint96 feeNumerator
	) external virtual {
		require(
			_isApprovedOrOwner(_msgSender(), tokenId),
			"ERC2981Royalty: caller is not owner nor approved"
		);
		_setTokenRoyalty(tokenId, receiver, feeNumerator);
	}

	/**
	 * @dev Resets royalty for the `tokenId` back to the default.
	 */
	function resetTokenRoyalty(uint256 tokenId) external virtual {
		require(
			_isApprovedOrOwner(_msgSender(), tokenId),
			"ERC2981Royalty: caller is not owner nor approved"
		);
		_resetTokenRoyalty(tokenId);
	}

	/**
	 * @notice Dude! Withdraw VET
	 */
	function withdraw() external onlyOwner {
		address payable admin = payable(owner());
		(bool success, ) = admin.call{ value: address(this).balance }("");
		require(success, "Failed to Withdraw VET");
	}

	/**
	 * @dev Fetch token list of `_owner`
	 * @param _owner address for checking tokens
	 * @return Token list of `_owner` have
	 */
	function tokensOfOwner(address _owner)
		external
		view
		returns (uint256[] memory)
	{
		uint256 tokenCount = balanceOf(_owner);
		if (tokenCount == 0) {
			// Return an empty array
			return new uint256[](0);
		} else {
			uint256[] memory result = new uint256[](tokenCount);
			for (uint256 index = 0; index < tokenCount; index++) {
				result[index] = tokenOfOwnerByIndex(_owner, index);
			}
			return result;
		}
	}

	/// @dev Gets max limit of token
	function getMaxLimit() external view returns (uint256) {
		return MAX_PLANET;
	}

	/// @dev Gets giveaway address
	function getGiveAwayAddress() external view returns (address) {
		return _giveawayAddress;
	}

	/// @dev Gets the limit mints for giveaway
	function getTotalMintsForGiveaway() external view returns (uint256) {
		return _totalMintsForGiveaway;
	}

	/// @dev Gets maximum pending mints in each process
	function getMaxPendingMintsToProcess() external view returns (uint256) {
		return _maxPendingMintsToProcess;
	}

	/// @dev Gets oracleRandom address
	function getOracleRandom() external view returns (address) {
		return _oracleRandom;
	}

	/// @dev Gets pending list
	function getPendingId() external view returns (uint256[] memory) {
		return _indexPendingMints;
	}

	/// @dev Gets tier block number
	function getBlockLimit(uint8 index) external view returns (uint256) {
		require(index >= 0 && index < 9, "Invalied index of array");
		return TIER_BLOCK[index];
	}

	/// @dev Gets NFT price in tier
	function getTierPrice(uint8 index) external view returns (uint256) {
		require(index >= 0 && index < 5, "Invalied index of array");
		return TIER_PRICE[index];
	}

	/// @dev Gets the limit mint in tier
	function getTierMintLimit(uint8 index) external view returns (uint256) {
		require(index >= 0 && index < 5, "Invalied index of array");
		return TIER_MINT_LIMIT[index];
	}

	/// @dev Gets the estimate NFT of `pm_address` in tier
	function getEstimateNFT(address pm_address) external view returns (uint8) {
		uint8 tier_num = getTierNumber(pm_address);
		if (tier_num == 0) {
			return uint8(0);
		}
		return
			uint8(
				TIER_MINT_LIMIT[tier_num - 1] - _mintCounter[tier_num - 1][pm_address]
			);
	}

	/// @dev Gets NFT price when `caller` call this function
	function getPrice() public view returns (uint256) {
		uint256 tier_num = getTierNumber(_msgSender());
		require(tier_num > 0, "Not available to mint");
		return TIER_PRICE[tier_num - 1];
	}

	/**
	 * @notice Generate the random number for minting
	 * @dev Get random number with `top`, `seed`, and information of block
	 *
	 * @param top a parameter just like in doxygen (must be followed by parameter name)
	 * @param seed a parameter just like in doxygen (must be followed by parameter name)
	 * @param currentPendingList a parameter just like in doxygen (must be followed by parameter name)
	 *
	 * @return Random uint256
	 */
	function getRandomNumber(
		uint256 top,
		uint256 seed,
		uint256 currentPendingList
	) public view returns (uint256) {
		// get a number from [1, top]
		uint256 randomHash = uint256(
			keccak256(
				abi.encodePacked(
					block.difficulty,
					block.timestamp,
					currentPendingList,
					seed
				)
			)
		);

		uint256 result = randomHash % top;
		return result;
	}

	/**
	 * @notice Get tier number of `pm_address`
	 * @dev Calculate tier number with block number(timestamp) and whitelist
	 * @param pm_address address to get tier number
	 * @return uint8 Tier number
	 * valid: 1~5
	 * invalid: 0
	 */
	function getTierNumber(address pm_address) public view returns (uint8) {
		uint256 curBlock = block.number;
		if (curBlock >= TIER_BLOCK[0] && curBlock < TIER_BLOCK[1]) {
			if (_whitelister[pm_address] & uint8(1) != 0) {
				return 1;
			}
		}
		if (curBlock >= TIER_BLOCK[2] && curBlock < TIER_BLOCK[3]) {
			if (_whitelister[pm_address] & uint8(2) != 0) {
				return 2;
			}
		}
		if (curBlock >= TIER_BLOCK[4] && curBlock < TIER_BLOCK[5]) {
			if (_whitelister[pm_address] & uint8(3) != 0) {
				return 3;
			}
		}
		if (curBlock >= TIER_BLOCK[6] && curBlock < TIER_BLOCK[7]) {
			if (_whitelister[pm_address] & uint8(4) != 0) {
				return 4;
			}
		}
		if (curBlock >= TIER_BLOCK[8]) {
			return 5;
		}
		return 0;
	}

	/// @dev Safely mints `tokenId` and transfers it to `to`
	function safeMint(address to, uint256 tokenId) public onlyOwner {
		_safeMint(to, tokenId);
	}

	/**
	 * @notice Explain to an end user what this does
	 * @dev Burn token and transfer it to null address
	 * Remove tokenURI of `tokenId`
	 *
	 * @param tokenId Token Id to burn
	 *
	 * Requirements:
	 *
	 * - Only owner of contract can call this function, not owner of tokenId
	 */
	function tokenBurn(uint256 tokenId) public virtual onlyOwner {
		_burn(tokenId);
	}

	/// @dev Pause all transfers
	function pause() public onlyOwner {
		_pause();
	}

	/// @dev Returns to normal state
	function unpause() public onlyOwner {
		_unpause();
	}

	// The trick to change the metadata if necessary and have a reveal moment
	function setBaseURI(string memory baseURI_) public onlyOwner {
		_setBaseURI(baseURI_);
	}

	function baseURI() public view returns (string memory) {
		return _baseURI();
	}

	/// @dev Returns the tokenURI of `tokenId`
	function tokenURI(uint256 tokenId)
		public
		view
		override(ERC721Upgradeable, ERC721URIStorageUpgradeable)
		returns (string memory)
	{
		return super.tokenURI(tokenId);
	}

	/// @dev See {IERC165-supportsInterface}.
	function supportsInterface(bytes4 interfaceId)
		public
		view
		override(ERC721Upgradeable, ERC721EnumerableUpgradeable, ERC2981Upgradeable)
		returns (bool)
	{
		return super.supportsInterface(interfaceId);
	}

	/// @dev Sets the token base URI
	function _setBaseURI(string memory baseURI_) internal virtual onlyOwner {
		_baseTokenURI = baseURI_;
	}

	/// @dev Override baseURI with `_baseTokenURI`
	function _baseURI() internal view override returns (string memory) {
		return _baseTokenURI;
	}

	/// @dev Burn `tokenId`
	/// Includes remove token uri, reset royalty of token, transfer token to null address.
	function _burn(uint256 tokenId)
		internal
		override(ERC721Upgradeable, ERC721URIStorageUpgradeable)
	{
		super._burn(tokenId);
		_resetTokenRoyalty(tokenId);
	}

	/// @dev Hook that is called before any token transfer.
	function _beforeTokenTransfer(
		address from,
		address to,
		uint256 tokenId
	)
		internal
		override(ERC721Upgradeable, ERC721EnumerableUpgradeable)
		whenNotPaused
	{
		super._beforeTokenTransfer(from, to, tokenId);
	}

	function _isFullyInitialized() internal virtual returns (bool) {
		return _initCounter >= MAX_PLANET;
	}

	/// @dev Remove Token from available token list
	function _removeTokenFromAvailableList(uint256 index) internal {
		require(
			index < _availableTokens.length,
			"index needs to be lower than length"
		);
		_availableTokens[index] = _availableTokens[_availableTokens.length - 1];
		_availableTokens.pop();
	}

	/// @dev Remove request from pending list
	function _removeIdFromPendingList(uint256 index) internal {
		require(
			index < _indexPendingMints.length,
			"index needs to be lower than length"
		);
		_indexPendingMints[index] = _indexPendingMints[
			_indexPendingMints.length - 1
		];
		_indexPendingMints.pop();
	}
}
