import { expect } from "chai";
import { ethers, network } from "hardhat";
import { decodeEvents } from "./utils/events";

import { deployContract } from "./utils/contracts";
import {
  convertSignatureToEIP2098,
  defaultAcceptOfferMirrorFulfillment,
  defaultBuyNowMirrorFulfillment,
  getBasicOrderExecutions,
  getBasicOrderParameters,
  getItemETH,
  random128,
  randomBN,
  randomHex,
  toAddress,
  toBN,
  toKey,
} from "./utils/encoding";
import { faucet } from "./utils/faucet";
import { seaportFixture } from "./utils/fixtures";
import { VERSION, minRandom, simulateMatchOrders } from "./utils/helpers";

import type {
  ConduitInterface,
  ConsiderationInterface,
  EIP1271Wallet,
  EIP1271Wallet__factory,
  TestERC20,
  TestERC721,
  TestZone,
} from "../typechain-types";
import type { SeaportFixtures } from "./utils/fixtures";
import type { Wallet,Contract } from "ethers";

const { parseEther, keccak256 } = ethers.utils;

/**
 * Buy now or accept offer for a single ERC721 or ERC1155 in exchange for
 * ETH, WETH or ERC20
 */
describe(`Basic buy now or accept offer flows (Seaport v${VERSION})`, function () {
  const { provider } = ethers;
  const owner = new ethers.Wallet(randomHex(32), provider);

  let conduitKeyOne: string;
  let conduitOne: ConduitInterface;
  let EIP1271WalletFactory: EIP1271Wallet__factory;
  let marketplaceContract: ConsiderationInterface;
  let stubZone: TestZone;
  let testERC20: TestERC20;
  let testERC721: TestERC721;

  let checkExpectedEvents: SeaportFixtures["checkExpectedEvents"];
  let createMirrorAcceptOfferOrder: SeaportFixtures["createMirrorAcceptOfferOrder"];
  let createMirrorBuyNowOrder: SeaportFixtures["createMirrorBuyNowOrder"];
  let createOrder: SeaportFixtures["createOrder"];
  let getTestItem1155: SeaportFixtures["getTestItem1155"];
  let getTestItem20: SeaportFixtures["getTestItem20"];
  let getTestItem721: SeaportFixtures["getTestItem721"];
  let mint721: SeaportFixtures["mint721"];
  let mintAndApprove1155: SeaportFixtures["mintAndApprove1155"];
  let mintAndApprove721: SeaportFixtures["mintAndApprove721"];
  let mintAndApproveERC20: SeaportFixtures["mintAndApproveERC20"];
  let set721ApprovalForAll: SeaportFixtures["set721ApprovalForAll"];
  let withBalanceChecks: SeaportFixtures["withBalanceChecks"];
   
  async function createZone(pausableZoneController: Contract, salt?: string) {
    const tx = await pausableZoneController.createZone(salt ?? randomHex());

    const zoneContract = await ethers.getContractFactory("PausableZone", owner);

    const events = await decodeEvents(tx, [
      { eventName: "ZoneCreated", contract: pausableZoneController },
      { eventName: "Unpaused", contract: zoneContract as any },
    ]);
    expect(events.length).to.be.equal(2);

    const [unpauseEvent, zoneCreatedEvent] = events;
    expect(unpauseEvent.eventName).to.equal("Unpaused");
    expect(zoneCreatedEvent.eventName).to.equal("ZoneCreated");

    return zoneCreatedEvent.data.zone as string;
  }
  
  after(async () => {
    await network.provider.request({
      method: "hardhat_reset",
    });
  });

  before(async () => {
    await faucet(owner.address, provider);

    ({
      checkExpectedEvents,
      conduitKeyOne,
      conduitOne,
      createMirrorAcceptOfferOrder,
      createMirrorBuyNowOrder,
      createOrder,
      EIP1271WalletFactory,
      getTestItem1155,
      getTestItem20,
      getTestItem721,
      marketplaceContract,
      mint721,
      mintAndApprove1155,
      mintAndApprove721,
      mintAndApproveERC20,
      set721ApprovalForAll,
      stubZone,
      testERC20,
      testERC721,
      withBalanceChecks,
    } = await seaportFixture(owner));
  });

  let seller: Wallet;
  let buyer: Wallet;
  let zone: Wallet;
  let swapVault:Wallet;
  let danil:Wallet;

  let sellerContract: EIP1271Wallet;
  let buyerContract: EIP1271Wallet;

  beforeEach(async () => {
    // Setup basic buyer/seller wallets with ETH
    seller = new ethers.Wallet(randomHex(32), provider);
    buyer = new ethers.Wallet(randomHex(32), provider);
    swapVault =  new ethers.Wallet(randomHex(32), provider);
    zone = new ethers.Wallet(randomHex(32), provider);

    sellerContract = await EIP1271WalletFactory.deploy(seller.address);
    buyerContract = await EIP1271WalletFactory.deploy(buyer.address);

    for (const wallet of [seller, buyer, zone, sellerContract, buyerContract]) {
      await faucet(wallet.address, provider);
    }
  });

  describe("NFT transfers", async () => {
    describe("swaping different erc types", async () => {
        it("ERC721 <=> ETH (native)", async () => {
            
            const nftId = await mintAndApprove721(
              seller,
              marketplaceContract.address
            );

            const offer = [getTestItem721(nftId)];
    
            const consideration =  [{
                itemType: 0, // ETH
                token: ethers.constants.AddressZero,
                identifierOrCriteria: toBN(0), // ignored for ETH
                startAmount: ethers.utils.parseEther("10"),
                endAmount: ethers.utils.parseEther("10"),
                recipient: seller.address,
              },
              {//zone payment  to initial nft owner
                itemType: 0, // ETH
                token: ethers.constants.AddressZero,
                identifierOrCriteria: toBN(0), // ignored for ETH
                startAmount: ethers.utils.parseEther("1"),
                endAmount: ethers.utils.parseEther("1"),
                recipient: zone.address,
              },
              {//payment to initial nft owner
                itemType: 0, // ETH
                token: ethers.constants.AddressZero,
                identifierOrCriteria: toBN(0), // ignored for ETH
                startAmount: ethers.utils.parseEther("1"),
                endAmount: ethers.utils.parseEther("1"),
                recipient: owner.address,
              }]
            const { order, orderHash, value } = await createOrder(
              seller,
              zone,
              offer,
              consideration,
              0 
            );
    
            const basicOrderParameters = getBasicOrderParameters(
              0, // EthForERC721
              order
            );

           const receipt = await withBalanceChecks([order], 0, undefined, async () => {
            const tx = marketplaceContract
                .connect(buyer)
                .fulfillBasicOrder(basicOrderParameters, {
                  value,
                });

              const receipt = await (await tx).wait();
              await checkExpectedEvents(tx, receipt, [
                {
                  order,
                  orderHash,
                  fulfiller: buyer.address,
                },
              ]);

            //   console.log('SELLER BALANCE',ethers.utils.formatEther(await seller.getBalance()))

              return receipt;
            });
      });
      it(" 2 ERC721 + ERC20 <=> ERC20 w/o tip ", async () => {            
            const nftId = await mintAndApprove721(
              seller,
              marketplaceContract.address
            );
            const nftId2 = await mintAndApprove721(
                seller,
                marketplaceContract.address
            );
            await mintAndApproveERC20(
                seller,
                marketplaceContract.address,
                200
            );

            // Buyer mints ERC20 and approves tokens for 'seaport.sol' contract address
            const tokenAmount = minRandom(100);
            await mintAndApproveERC20(
              buyer,
              marketplaceContract.address,
              tokenAmount
            );

            const nft1 = getTestItem721(nftId)
            const nft2 = getTestItem721(nftId2)
            const erc20 = getTestItem20(200,200)
            //for ex I offer 2 nft + erc20
            //step 1
            const offer = [nft1,nft2,erc20];
            
            //I want to get 100 erc for myself,and 50 for an nft initial owner
            //step 2
            const consideration = [
              getTestItem20(
                tokenAmount.sub(100),
                tokenAmount.sub(100),
                seller.address
              ),//I want to get 100 erc for myself
              getTestItem20(50, 50, owner.address),//and 50 for an nft initial owner

            ];
            
            //
            const { order, orderHash } = await createOrder(
              seller,
              zone,
              offer,
              consideration,
              0
            );

            const tx = marketplaceContract
                .connect(buyer)
                .fulfillOrder(order, toKey(0));
            
            await (await tx).wait();

     });
     it("ERC20 <=> ERC20 + ERC712 + ERC1155 ", async () => {
      // Buyer mints erc1155
      const { nftId, amount } = await mintAndApprove1155(
        buyer,
        marketplaceContract.address
      );

      // Seller mints ERC20
      const tokenAmount = minRandom(100);
      await mintAndApproveERC20(
        seller,
        marketplaceContract.address,
        tokenAmount
      );
      //buyer mints ERC1155
      const tokenErc1155 = await mintAndApprove721(
        buyer,
        marketplaceContract.address
      );

      // Buyer approves marketplace contract to transfer ERC20 tokens too
      await expect(
        testERC20
          .connect(buyer)
          .approve(marketplaceContract.address, tokenAmount)
      )
        .to.emit(testERC20, "Approval")
        .withArgs(buyer.address, marketplaceContract.address, tokenAmount);

      const offer = [
        getTestItem20(tokenAmount.sub(100), tokenAmount.sub(100)),
      ];

      const consideration = [
        getTestItem1155(nftId, amount, amount, undefined, seller.address),
        getTestItem20(50, 50, zone.address),
        getTestItem20(50, 50, owner.address),
        getTestItem721(tokenErc1155, 1, 1, seller.address)
      ];

      const { order, orderHash } = await createOrder(
        seller,
        zone,
        offer,
        consideration,
        0 // FULL_OPEN
      );

      await withBalanceChecks([order], 0, undefined, async () => {
        const tx = marketplaceContract
          .connect(buyer)
          .fulfillOrder(order, toKey(0));
        const receipt = await (await tx).wait();
        await checkExpectedEvents(tx, receipt, [
          {
            order,
            orderHash,
            fulfiller: buyer.address,
            fulfillerConduitKey: toKey(0),
          },
        ]);

        return receipt;
      });
    });
    it(" 2 ERC721 + ERC20 <=> ERC20 with a tip", async () => {            
      //minting for the seller 2 nft + erc20
      const nftId = await mintAndApprove721(
        seller,
        marketplaceContract.address
      );
      const nftId2 = await mintAndApprove721(
          seller,
          marketplaceContract.address
      );
      await mintAndApproveERC20(
          seller,
          marketplaceContract.address,
          200
      );

      // buyer mints ERC20 and approves tokens for 'seaport.sol' contract addr
      const tokenAmount = minRandom(100);
      await mintAndApproveERC20(
        buyer,
        marketplaceContract.address,
        tokenAmount
      );
        await mintAndApproveERC20(
        buyer,
        marketplaceContract.address,
        tokenAmount
      );

      const nft1 = getTestItem721(nftId)
      const nft2 = getTestItem721(nftId2)
      const erc20= getTestItem20(200,200)

      //for ex I offer 2 nft + erc20

      const offer = [nft1,nft2,erc20];
      
      //I want to get 100 erc for myself,and 50 for an nft initial owner
      const consideration = [
        getTestItem20(
          tokenAmount.sub(100),
          tokenAmount.sub(100),
          seller.address
        ),//I want to get 100 erc for myself
        getTestItem20(50, 50, owner.address),//and 50 for an nft initial owner

      ];
      
      //
      const { order, value ,orderHash } = await createOrder(
        seller,
        zone,
        offer,
        consideration,
        0
      );
      //adding a tip for the seller
    
      order.parameters.consideration.push(getItemETH(parseEther("1"), parseEther("1"), seller.address))

      const tx = marketplaceContract
          .connect(buyer)
          .fulfillOrder(order, toKey(0),{
            value:value.add(parseEther("1"))
          });
      
      await (await tx).wait();

    });
     it("ERC721 <=> ETH + ERC20 + ERC721 with a tip", async () => {
      //MINT & APPROVE FOR PARTICIPANTS
        const nftId = await mintAndApprove721(
          seller,
          marketplaceContract.address
        );
        
        const nftId2 = await mintAndApprove721(
          buyer,
          marketplaceContract.address
        );
        
        await mintAndApproveERC20(
          buyer,
          marketplaceContract.address,
          10000
        );

        const nft1 = getTestItem721(nftId)    
        const nft2 = getTestItem721(nftId2, 1, 1, seller.address)

        const offer = [nft1];
        
        console.log('owner of offered item before trade',await testERC721.ownerOf(nft1.identifierOrCriteria))
        console.log('owner of consideration items before trade',await testERC721.ownerOf(nft2.identifierOrCriteria))
        console.log('seller eth balance before trade',ethers.utils.formatEther(await seller.getBalance()))
        console.log('swapVault bal: before',ethers.utils.formatEther(await swapVault.getBalance()))

        const consideration = [ 
          getItemETH(parseEther("0.01"), parseEther("0.01"), swapVault.address),
          getTestItem20(
            10000,
            10000,
            seller.address
          ),
          getItemETH(parseEther("20"), parseEther("20"), seller.address),
          nft2
        ];

        const { order, orderHash, value,orderComponents } = await createOrder(
          seller,
          zone,//0x0000
          offer,
          consideration,
          0 // FULL_OPEN
        );
        
        // Add a tip/fee  getItemETH(parseEther("1"), parseEther("1"), owner.address)
        order.parameters.consideration.push(getItemETH(parseEther("1"), parseEther("1"), seller.address))
        const tx = marketplaceContract.connect(buyer).fulfillOrder(order, toKey(0), {
            value:value.add(parseEther("1"))
        })
        await (await tx).wait();

        console.log('owner of consideration items after',await testERC721.ownerOf(nft2.identifierOrCriteria))
        console.log('owner of offered item owner after',await testERC721.ownerOf(nft1.identifierOrCriteria))
        console.log('seller eth balance after trade',await ethers.utils.formatEther(await seller.getBalance()))

        });
      it("Can cancel an order", async () => {
        // Seller mints nft
        const nftId = await mintAndApprove721(
          seller,
          marketplaceContract.address
        );
  
        const offer = [getTestItem721(nftId)];
        const consideration = [
          getItemETH(parseEther("10"), parseEther("10"), seller.address),
          getItemETH(parseEther("1"), parseEther("1"), zone.address),
          getItemETH(parseEther("1"), parseEther("1"), owner.address),
        ];
  
        const { order, orderHash, value, orderComponents } = await createOrder(
          seller,
          zone,
          offer,
          consideration,
          0 
        );

        await expect(
          marketplaceContract.connect(seller).cancel([orderComponents])
        ).to.emit(marketplaceContract, "OrderCancelled")
          .withArgs(orderHash, seller.address, zone.address);
  
        // cannot fill the order anymore
        await expect(
          marketplaceContract.connect(buyer).fulfillOrder(order, toKey(0), {
            value,
          })
        ).to.be.reverted;
  
      });
     
    })
    it("Fulfills an order with a pausable zone", async () => {
        const pausableDeployer = await ethers.getContractFactory(
          "PausableZoneController",
          owner
        );
        const deployer = await pausableDeployer.deploy(owner.address);
    
        const zoneAddr = await createZone(deployer);
    
        // create basic order using pausable as zone
        // execute basic 721 <=> ETH order
        const nftId = await mintAndApprove721(seller, marketplaceContract.address);
    
        const offer = [getTestItem721(nftId)];
    
        const consideration = [
          getItemETH(parseEther("10"), parseEther("10"), seller.address),
          getItemETH(parseEther("1"), parseEther("1"), owner.address),
        ];
    
        const { order, orderHash, value } = await createOrder(
          seller,
          zoneAddr,
          offer,
          consideration,
          2 // FULL_RESTRICTED
        );
    
        await withBalanceChecks([order], 0, undefined, async () => {
          const tx = await marketplaceContract
            .connect(buyer)
            .fulfillOrder(order, toKey(0), {
              value,
            });
    
          const receipt = await tx.wait();
          await checkExpectedEvents(tx, receipt, [
            {
              order,
              orderHash,
              fulfiller: buyer.address,
              fulfillerConduitKey: toKey(0),
            },
          ]);
          return receipt;
        });
      });
  })
})