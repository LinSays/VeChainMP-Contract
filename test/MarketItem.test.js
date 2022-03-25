const { assert, expect } = require("chai");
const { BN, constants, expectEvent, expectRevert, time } = require('@openzeppelin/test-helpers');
const { web3 } = require("@openzeppelin/test-helpers/src/setup");
const { ZERO_ADDRESS } = constants;
const TransparentUpgradeableProxy = artifacts.require('TransparentUpgradeableProxy');
const PlanetNFT = artifacts.require('PlanetNFT');
const Marketplace = artifacts.require('Marketplace');
const IMarketplace = artifacts.require('IMarketplace');
const DAO_WALLET = "0x52F95613130c07F0efdb21b263F3FB84DF3E77C5";

contract("Marketplace unit tests", async (accounts) => {
  let trans, planetNFT, marketplace;
  let createDirectItemParams, createAuctionItemParams;
  const [minter, alice, bob, carol, dan] = accounts;

  before(async () => {
    trans = await TransparentUpgradeableProxy.deployed();
    planetNFT = await PlanetNFT.at(trans.address);
    // Safe mint test tokens
    await planetNFT.safeMint(alice, 10, { from: minter });
    await planetNFT.safeMint(bob, 11, { from: minter });
    await planetNFT.safeMint(alice, 12, { from: minter });
    await planetNFT.safeMint(bob, 13, { from: minter });
    await planetNFT.safeMint(alice, 14, { from: minter });
    await planetNFT.safeMint(bob, 15, { from: minter });
    await planetNFT.setDefaultRoyalty(DAO_WALLET, 500, { from: minter });
    // Marketplace
    marketplace = await Marketplace.deployed();
    await marketplace.setAssetAddress(planetNFT.address);
  });
  describe("Create marketplace item", () => {
    it("Create item for direct sale", async () => {
      const price = new BN(web3.utils.toWei('2', 'ether'));
      // Approve token `0` to MarketPlace
      await planetNFT.setApprovalForAll(marketplace.address, true, { from: alice });
      // Create marketplace item for direct sale - token `0`
      // Sets direct sale item params
      createDirectItemParams = [
        10,
        0,
        0,
        0,
        price,
        IMarketplace.ListingType.Direct
      ];
      await marketplace.createMarketItem(createDirectItemParams, { from: alice });

      const newItem = await marketplace.getItemByTokenId(10);
      assert.equal(newItem.itemId.toString(), "0");
      assert.equal(newItem.tokenOwner, alice);
      assert.equal(newItem.tokenId.toString(), "10");
      assert.equal(newItem.buyoutTokenPrice, price);
      assert.equal(newItem.listingType, IMarketplace.ListingType.Direct);
    });
    it("Create direct sale item with `_tokenId` and `_price`", async () => {
      const price = new BN(web3.utils.toWei('2', 'ether'));
      // Create market item for direct sale
      await marketplace.createDirectSaleItem(12, price, { from: alice });

      const newItem = await marketplace.getItemByTokenId(12);
      assert.equal(newItem.tokenOwner, alice);
      assert.equal(newItem.tokenId.toString(), "12");
      assert.equal(newItem.buyoutTokenPrice, price);
      assert.equal(newItem.listingType, IMarketplace.ListingType.Direct);
    });
    it("Revert: duplicate create market item", async () => {
      const price = new BN(web3.utils.toWei('2', 'ether'));
      // Check duplicate listing
      await expectRevert(
        marketplace.createDirectSaleItem(12, price, { from: alice }),
        "Marketplace: market item already exists"
      );
    });
    it("Create auction item", async () => {
      const reserveTokenPrice = new BN(web3.utils.toWei('1', 'ether'));
      const buyoutTokenPrice = new BN(web3.utils.toWei('2', 'ether'));
      // Approve token `11` to MP
      await planetNFT.approve(marketplace.address, 11, { from: bob });
      // Sets the auction start time
      const startTime = (await time.latest()).add(time.duration.seconds(25));
      // Sets item params for an auction
      createAuctionItemParams = [
        11,
        startTime,
        time.duration.days(1),
        reserveTokenPrice,
        buyoutTokenPrice,
        IMarketplace.ListingType.Auction
      ];
      // Create marketplace item for auction - token `1`
      await marketplace.createMarketItem(createAuctionItemParams, { from: bob });

      const newItem = await marketplace.getItemByTokenId(11);
      assert.equal(newItem.tokenOwner, bob);
      assert.equal(newItem.tokenId.toString(), "11");
      assert.equal(newItem.startTime, startTime);
      assert.equal(newItem.endTime, startTime.add(time.duration.days(1)));
      assert.equal(newItem.reserveTokenPrice, reserveTokenPrice);
      assert.equal(newItem.buyoutTokenPrice, buyoutTokenPrice);
      assert.equal(newItem.listingType, IMarketplace.ListingType.Auction);
    });
    it("Revert: secondsUntilEndTime must be greater than 0", async () => {
      createAuctionItemParams[0] = 13;
      createAuctionItemParams[2] = 0;
      await expectRevert(
        marketplace.createMarketItem(createAuctionItemParams, { from: bob }),
        "Marketplace: secondsUntilEndTime must be greater than 0"
      );
      createAuctionItemParams[0] = 11;
      createAuctionItemParams[2] = time.duration.days(1);
    });
    it("Revert: lister must be owner of token", async () => {
      createDirectItemParams[0] = 15;
      await expectRevert(
        marketplace.createMarketItem(createDirectItemParams, { from: alice }),
        "Marketplace: invalid ownership or approval"
      );
      createDirectItemParams[0] = 13;
      await expectRevert(
        marketplace.createMarketItem(createDirectItemParams, { from: bob }),
        "Marketplace: invalid ownership or approval"
      );
    });
    it("Revert: buyout price must be greater than reserve price", async () => {
      createAuctionItemParams[0] = 13;
      createAuctionItemParams[3] = new BN(web3.utils.toWei('2', 'ether'));
      createAuctionItemParams[4] = new BN(web3.utils.toWei('1', 'ether'));
      // Approve token `0` to MarketPlace
      await planetNFT.approve(marketplace.address, 13, { from: bob });
      await expectRevert(
        marketplace.createMarketItem(createAuctionItemParams, { from: bob }),
        "Marketplace: reserve price exceeds buyout price"
      );
      createAuctionItemParams[0] = 11;
      createAuctionItemParams[3] = new BN(web3.utils.toWei('1', 'ether'));
      createAuctionItemParams[4] = new BN(web3.utils.toWei('2', 'ether'));
    });
  });
  describe("Update marketing item", () => {
    let updateBuyoutPrice = new BN(web3.utils.toWei('1', 'ether'));
    it("Update direct sale item", async () => {
      let receipt = await marketplace.updateMarketItem(
        10,
        0,
        updateBuyoutPrice,
        0,
        0,
        { from: alice }
      );
      expectEvent(
        receipt,
        "UpdateMarketItem",
        {
          itemId: new BN(0),
          tokenId: new BN(10),
          lister: alice
        }
      );
      let updateItem = await marketplace.getItemByTokenId(10);
      assert.equal(updateItem.buyoutTokenPrice, updateBuyoutPrice);
      updateBuyoutPrice = new BN(web3.utils.toWei('3', 'ether'));
      receipt = await marketplace.updateDirectSaleItem(
        10,
        updateBuyoutPrice,
        { from: alice }
      );
      expectEvent(
        receipt,
        "UpdateMarketItem",
        {
          itemId: new BN(0),
          tokenId: new BN(10),
          lister: alice
        }
      );
      updateItem = await marketplace.getItemByTokenId(10);
      assert.equal(updateItem.buyoutTokenPrice, updateBuyoutPrice);
    });
    it("Revert: Market item must be updated by lister", async () => {
      await expectRevert(
        marketplace.updateMarketItem(
          11,
          0,
          updateBuyoutPrice,
          0,
          time.duration.days(3),
          { from: alice }
        ),
        "Marketplace: caller is not listing creator"
      );
    })
    it("Revert: Auction item's `buyoutPrice` must be greater than `reservePrice`", async () => {
      const updateReservePrice = new BN(web3.utils.toWei('3', 'ether'));
      const updateBuyoutPrice = new BN(web3.utils.toWei('2', 'ether'));
      await expectRevert(
        marketplace.updateMarketItem(
          11,
          updateReservePrice,
          updateBuyoutPrice,
          0,
          0,
          { from: bob }
        ),
        "Marketplace: reserve price exceeds buyout price"
      );
    });
    it("Revert: Auction item timestamp", async () => {
      await time.increase(time.duration.seconds(15))
      const updatedStartTime = (await time.latest()).add(time.duration.seconds(3));
      const updateReservePrice = new BN(web3.utils.toWei('2', 'ether'));
      const updateBuyoutPrice = new BN(web3.utils.toWei('3', 'ether'));
      await expectRevert(
        marketplace.updateMarketItem(
          11,
          updateReservePrice,
          updateBuyoutPrice,
          updatedStartTime,
          time.duration.days(3),
          { from: bob }
        ),
        "Marketplace: auction has already started"
      );
    });
  })
  describe("Direct Sale Item", () => {
    describe("Validate Direct Sale Item", () => {
      it("Invalid buy out price", async () => {
        await expectRevert(
          marketplace.buy(10, { from: carol, value: web3.utils.toWei('1', 'ether') }),
          "Marketplace: invalid price"
        );
      });
      it("Invalid listing type", async () => {
        await expectRevert(
          marketplace.buy(11, { from: carol, value: web3.utils.toWei('2', 'ether') }),
          "Marketplace: invalid listing type"
        );
      })
    })
    describe("Buy NFT: executeSale", async () => {
      it("Payment split", async () => {
        const beforeTreasuryWallet = new BN(await web3.eth.getBalance(DAO_WALLET));
        const beforeSellerWallet = new BN(await web3.eth.getBalance(alice));
        const receipt = await marketplace.buy(12, { from: carol, value: web3.utils.toWei('2', 'ether') });
        const afterTreasuryWallet = new BN(await web3.eth.getBalance(DAO_WALLET));
        const afterSellerWallet = new BN(await web3.eth.getBalance(alice));
        const fee = new BN(web3.utils.toWei('0.1', 'ether'));
        const remain = new BN(web3.utils.toWei('1.9', 'ether'));
        assert.equal(afterTreasuryWallet.toString(), (beforeTreasuryWallet.add(fee)).toString());
        assert.equal(afterSellerWallet.toString(), (beforeSellerWallet.add(remain)).toString());
        expectEvent(
          receipt,
          "NewSale",
          {
            seller: alice,
            buyer: carol,
            itemId: new BN(1),
            tokenId: new BN(12),
            buyoutPrice: new BN(web3.utils.toWei('2', 'ether'))
          }
        );
      })
      it("NFT transfer", async () => {
        const newOwner = await planetNFT.ownerOf(12);
        assert.equal(newOwner, carol);
        // Check if market item removed from listing
        await expectRevert(
          marketplace.getItemByTokenId(12),
          "Marketplace: non exist marketplace item"
        )
        let item = await marketplace.getItemByTokenId(11);
        assert.equal(item.tokenId, 11);
        item = await marketplace.getItemByTokenId(10);
        assert.equal(item.tokenId, 10);
        item = await marketplace.getItemByMarketId(0);
        assert.equal(item.itemId, 0);
        item = await marketplace.getItemByMarketId(2);
        assert.equal(item.itemId, 2);
        await expectRevert(
          marketplace.getItemByMarketId(1),
          "Marketplace: non exist marketplace item"
        )
      })
    })
    describe("Offer NFT", () => {
      it("Invalid offer price", async () => {
        await expectRevert(
          marketplace.offer(10, { from: bob }),
          "Marketplace: invalid offer price"
        );
      })
      it("Make offers: `bob` and `carol`", async () => {
        const receipt1 = await marketplace.offer(10, { from: bob, value: web3.utils.toWei('1.5', 'ether') });
        const receipt2 = await marketplace.offer(10, { from: carol, value: web3.utils.toWei('1', 'ether') });
        expectEvent(
          receipt1,
          "NewOffer",
          {
            offeror: bob,
            itemId: new BN(0),
            tokenId: new BN(10),
            offerPrice: new BN(web3.utils.toWei('1.5', 'ether')),
            listingType: new BN(IMarketplace.ListingType.Direct)
          }
        );
        expectEvent(
          receipt2,
          "NewOffer",
          {
            offeror: carol,
            itemId: new BN(0),
            tokenId: new BN(10),
            offerPrice: new BN(web3.utils.toWei('1', 'ether')),
            listingType: new BN(IMarketplace.ListingType.Direct)
          }
        );
      })
      it("Others cannot accept offer but lister", async () => {
        await expectRevert(
          marketplace.acceptOffer(10, bob, { from: dan }),
          "Marketplace: caller is not listing creator"
        );
        await expectRevert(
          marketplace.acceptOffer(10, bob, { from: bob }),
          "Marketplace: caller is not listing creator"
        );
      })
      it("Invalid offer", async () => {
        await expectRevert(
          marketplace.acceptOffer(10, dan, { from: alice }),
          "Marketplace: invalid offeror"
        );
      })
      it("Accept `bob` offer", async () => {
        const receipt = await marketplace.acceptOffer(10, bob, { from: alice });
        expectEvent(
          receipt,
          "NewSale",
          {
            seller: alice,
            buyer: bob,
            itemId: new BN(0),
            tokenId: new BN(10),
            buyoutPrice: new BN(web3.utils.toWei('1.5', 'ether'))
          }
        );
      })
      it("`bob` cannot cancel offer", async () => {
        await expectRevert(
          marketplace.cancelOffer(10, { from: bob }),
          "Marketplace: invalid offer"
        );
      })
      it("`carol` can cancel offer", async () => {
        const beforeWallet = await web3.eth.getBalance(carol);
        const receipt = await marketplace.cancelOffer(10, { from: carol });
        const afterWallet = await web3.eth.getBalance(carol);
        const tx = await web3.eth.getTransaction(receipt.tx);
        const gasPrice = new BN(tx.gasPrice);
        assert.equal(
          (new BN(afterWallet)).toString(),
          (new BN(beforeWallet)
            .add(new BN(web3.utils.toWei('1', 'ether')))
            .sub(new BN(receipt.receipt.gasUsed).mul(gasPrice))).toString());
      })
    })
  })
  describe("Auction", () => {
    describe("Cancel auction", () => {
      it("Lister or others cannot close auction", async () => {
        await expectRevert(
          marketplace.closeAuction(11, { from: alice }),
          "Ownable: caller is not the owner"
        );
        await expectRevert(
          marketplace.closeAuction(11, { from: bob }),
          "Ownable: caller is not the owner"
        );
      })
      it("Close auction without bidder or before start", async () => {
        const receipt = await marketplace.closeAuction(11, { from: minter });

        const owner = await planetNFT.ownerOf(11);
        assert.equal(owner, bob);

        // Check if market item removed
        await expectRevert(
          marketplace.getItemByTokenId(11),
          "Marketplace: non exist marketplace item"
        );

        // `AuctionClosed` event must be triggered
        expectEvent(
          receipt,
          "AuctionClosed",
          {
            itemId: new BN(2),
            tokenId: new BN(11),
            auctionCreator: bob,
            winningBidder: ZERO_ADDRESS,
            cancelled: true,
          }
        );
      })
    })
    describe("Execute auction", () => {
      before(async () => {
        // Create auction listing. this is already tested
        await planetNFT.approve(marketplace.address, 11, { from: bob });
        await marketplace.createMarketItem(createAuctionItemParams, { from: bob });
      })
      it("PlaceBid: `alice` cannot bid at low price than reserve price", async () => {
        await expectRevert(
          marketplace.offer(11, { from: alice, value: web3.utils.toWei('0.5', 'ether') }),
          "Marketplace: not winning bid"
        )
      })
      it("PlaceBid: `alice` place a bid", async () => {
        const receipt = await marketplace.offer(11, { from: alice, value: web3.utils.toWei('1', 'ether') });
        expectEvent(
          receipt,
          "NewOffer",
          {
            offeror: alice,
            itemId: new BN(3),
            tokenId: new BN(11),
            offerPrice: new BN(web3.utils.toWei('1', 'ether')),
            listingType: new BN(IMarketplace.ListingType.Auction)
          }
        )
      })
      it("PlaceBid: `carol` must place increase `bidBufferBps` %  price", async () => {
        await expectRevert(
          marketplace.offer(11, { from: carol, value: web3.utils.toWei('1.01', 'ether') }),
          "Marketplace: not winning bid"
        )
      })
      it("PlaceBid: `carol`, Refund to `alice` ", async () => {
        // Check refund
        const beforeAliceWallet = await web3.eth.getBalance(alice);
        await marketplace.offer(11, { from: carol, value: web3.utils.toWei('1.5', 'ether') });
        const afterAliceWallet = await web3.eth.getBalance(alice);
        assert.equal(
          (new BN(afterAliceWallet)).toString(),
          (new BN(beforeAliceWallet).add(new BN(web3.utils.toWei('1', 'ether')))).toString()
        );
        const winningBid = await marketplace.getWinningBid(11);
        assert.equal(winningBid.tokenId, 11);
        assert.equal(winningBid.offeror, carol);
        assert.equal((winningBid.offerPrice).toString(), web3.utils.toWei('1.5', 'ether'));
      })
      it("PlaceBid: `dan` bid at buyout price ", async () => {
        const fee = new BN(web3.utils.toWei('0.5', 'ether'));
        const remain = new BN(web3.utils.toWei('9.5', 'ether'));
        // Check refund
        const beforeCarolWallet = await web3.eth.getBalance(carol);
        const beforeTreasuryWallet = new BN(await web3.eth.getBalance(DAO_WALLET));
        const beforeSellerWallet = new BN(await web3.eth.getBalance(bob));
        const receipt = await marketplace.offer(11, { from: alice, value: web3.utils.toWei('10', 'ether') });
        const afterCarolWallet = await web3.eth.getBalance(carol);
        assert.equal(
          (new BN(afterCarolWallet)).toString(),
          (new BN(beforeCarolWallet).add(new BN(web3.utils.toWei('1.5', 'ether')))).toString()
        );
        expectEvent(
          receipt,
          "AuctionClosed",
          {
            itemId: new BN(3),
            tokenId: new BN(11),
            auctionCreator: bob,
            winningBidder: alice,
            cancelled: false
          }
        )
        // `alice` buyout price Token `11`
        const afterTreasuryWallet = new BN(await web3.eth.getBalance(DAO_WALLET));
        const afterSellerWallet = new BN(await web3.eth.getBalance(bob));

        assert.equal(afterTreasuryWallet.toString(), (beforeTreasuryWallet.add(fee)).toString());
        assert.equal(afterSellerWallet.toString(), (beforeSellerWallet.add(remain)).toString());

        const tokenOwner = await planetNFT.ownerOf(11);
        assert.equal(tokenOwner, alice);
      })
    })
  })
})
