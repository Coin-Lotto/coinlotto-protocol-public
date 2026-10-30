import { expect } from "chai";
import { ethers } from "hardhat";

describe("CoinLotto", function () {
  async function token() {
    const [owner, recipient, spender] = await ethers.getSigners();
    const endpoint = await ethers.deployContract("LzEndpointMock");
    const coin = await ethers.deployContract("CoinLotto", [await endpoint.getAddress(), owner.address, owner.address]);
    return { owner, recipient, spender, endpoint, coin };
  }

  describe("constructor", function () {
    it("should emit MinterSet with the initial minter", async function () {
      const { owner, coin } = await token();
      await expect(coin.deploymentTransaction()).to.emit(coin, "MinterSet").withArgs(owner.address);
    });

    it("should emit OwnershipTransferred from the zero address to the owner", async function () {
      const { owner, coin } = await token();
      await expect(coin.deploymentTransaction())
        .to.emit(coin, "OwnershipTransferred")
        .withArgs(ethers.ZeroAddress, owner.address);
    });
  });

  describe("mint", function () {
    it("should emit MinterSet clearing the minter", async function () {
      const { owner, coin } = await token();
      await expect(coin.mint(owner.address)).to.emit(coin, "MinterSet").withArgs(ethers.ZeroAddress);
    });

    it("should emit Transfer of the full supply", async function () {
      const { owner, coin } = await token();
      const supply = await coin.MAX_SUPPLY();
      await expect(coin.mint(owner.address))
        .to.emit(coin, "Transfer")
        .withArgs(ethers.ZeroAddress, owner.address, supply);
    });
  });

  describe("burn", function () {
    it("should emit Transfer to the zero address", async function () {
      const { owner, coin } = await token();
      await coin.mint(owner.address);
      const amount = ethers.parseEther("5");
      await expect(coin.burn(amount)).to.emit(coin, "Transfer").withArgs(owner.address, ethers.ZeroAddress, amount);
    });
  });

  describe("approve", function () {
    it("should emit Approval with the owner, spender, and amount", async function () {
      const { owner, recipient, coin } = await token();
      await coin.mint(owner.address);
      const amount = ethers.parseEther("5");
      await expect(coin.approve(recipient.address, amount))
        .to.emit(coin, "Approval")
        .withArgs(owner.address, recipient.address, amount);
    });
  });

  describe("transfer", function () {
    it("should emit Transfer with the sender, recipient, and amount", async function () {
      const { owner, recipient, coin } = await token();
      await coin.mint(owner.address);
      const amount = ethers.parseEther("4");
      await expect(coin.transfer(recipient.address, amount))
        .to.emit(coin, "Transfer")
        .withArgs(owner.address, recipient.address, amount);
    });
  });

  describe("transferFrom", function () {
    it("should emit Transfer moving the allowance holder's tokens", async function () {
      const { owner, recipient, spender, coin } = await token();
      await coin.mint(owner.address);
      const amount = ethers.parseEther("3");
      await coin.approve(spender.address, amount);
      await expect(coin.connect(spender).transferFrom(owner.address, recipient.address, amount))
        .to.emit(coin, "Transfer")
        .withArgs(owner.address, recipient.address, amount);
    });
  });

  describe("setPeer", function () {
    it("should emit PeerSet with the endpoint id and peer", async function () {
      const { recipient, coin } = await token();
      const peer = ethers.zeroPadValue(recipient.address, 32);
      await expect(coin.setPeer(2, peer)).to.emit(coin, "PeerSet").withArgs(2, peer);
    });
  });

  describe("setEnforcedOptions", function () {
    it("should emit EnforcedOptionSet with the option parameters", async function () {
      const { coin } = await token();
      const options = [{ eid: 2, msgType: 1, options: "0x0003" }];
      await expect(coin.setEnforcedOptions(options))
        .to.emit(coin, "EnforcedOptionSet")
        .withArgs([[2, 1, "0x0003"]]);
    });
  });

  describe("setMsgInspector", function () {
    it("should emit MsgInspectorSet with the inspector", async function () {
      const { owner, coin } = await token();
      await expect(coin.setMsgInspector(owner.address)).to.emit(coin, "MsgInspectorSet").withArgs(owner.address);
    });
  });

  describe("setPreCrime", function () {
    it("should emit PreCrimeSet with the pre-crime address", async function () {
      const { recipient, coin } = await token();
      await expect(coin.setPreCrime(recipient.address)).to.emit(coin, "PreCrimeSet").withArgs(recipient.address);
    });
  });

  describe("send", function () {
    async function ready() {
      const ctx = await token();
      await ctx.coin.mint(ctx.owner.address);
      const peer = ethers.zeroPadValue(ctx.owner.address, 32);
      await ctx.coin.setPeer(2, peer);
      const amount = ethers.parseEther("1");
      const sendParam = {
        dstEid: 2,
        to: ethers.zeroPadValue(ctx.recipient.address, 32),
        amountLD: amount,
        minAmountLD: amount,
        extraOptions: "0x",
        composeMsg: "0x",
        oftCmd: "0x",
      };
      return { ...ctx, peer, amount, sendParam };
    }

    it("should emit OFTSent with the guid, destination, sender, and amounts", async function () {
      const { owner, endpoint, coin, amount, sendParam } = await ready();
      await expect(coin.send(sendParam, { nativeFee: 0n, lzTokenFee: 0n }, owner.address))
        .to.emit(coin, "OFTSent")
        .withArgs(await endpoint.GUID(), 2, owner.address, amount, amount);
    });

    it("should emit Transfer burning the debited amount", async function () {
      const { owner, coin, amount, sendParam } = await ready();
      await expect(coin.send(sendParam, { nativeFee: 0n, lzTokenFee: 0n }, owner.address))
        .to.emit(coin, "Transfer")
        .withArgs(owner.address, ethers.ZeroAddress, amount);
    });
  });

  describe("lzReceive", function () {
    async function sent() {
      const ctx = await token();
      await ctx.coin.mint(ctx.owner.address);
      const peer = ethers.zeroPadValue(ctx.owner.address, 32);
      await ctx.coin.setPeer(2, peer);
      const amount = ethers.parseEther("1");
      await ctx.coin.send(
        {
          dstEid: 2,
          to: ethers.zeroPadValue(ctx.recipient.address, 32),
          amountLD: amount,
          minAmountLD: amount,
          extraOptions: "0x",
          composeMsg: "0x",
          oftCmd: "0x",
        },
        { nativeFee: 0n, lzTokenFee: 0n },
        ctx.owner.address,
      );
      const message = ethers.concat([
        ethers.zeroPadValue(ctx.recipient.address, 32),
        ethers.toBeHex(10n ** 6n, 8),
      ]);
      const origin = { srcEid: 2, sender: peer, nonce: 1n };
      return { ...ctx, amount, message, origin };
    }

    it("should emit OFTReceived with the guid, source, recipient, and amount", async function () {
      const { endpoint, coin, recipient, amount, message, origin } = await sent();
      await expect(endpoint.deliver(await coin.getAddress(), origin, await endpoint.GUID(), message))
        .to.emit(coin, "OFTReceived")
        .withArgs(await endpoint.GUID(), 2, recipient.address, amount);
    });

    it("should emit Transfer minting the credited amount", async function () {
      const { endpoint, coin, recipient, amount, message, origin } = await sent();
      await expect(endpoint.deliver(await coin.getAddress(), origin, await endpoint.GUID(), message))
        .to.emit(coin, "Transfer")
        .withArgs(ethers.ZeroAddress, recipient.address, amount);
    });
  });

  describe("transferOwnership", function () {
    it("should emit OwnershipTransferred to the new owner", async function () {
      const { owner, recipient, coin } = await token();
      await expect(coin.transferOwnership(recipient.address))
        .to.emit(coin, "OwnershipTransferred")
        .withArgs(owner.address, recipient.address);
    });
  });

  describe("renounceOwnership", function () {
    it("should emit OwnershipTransferred to the zero address", async function () {
      const { owner, coin } = await token();
      await expect(coin.renounceOwnership())
        .to.emit(coin, "OwnershipTransferred")
        .withArgs(owner.address, ethers.ZeroAddress);
    });
  });
});
