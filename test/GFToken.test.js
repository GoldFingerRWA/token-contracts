const GFToken = artifacts.require("GFToken");

contract("GFToken", accounts => {
  let gfToken;
  const owner = accounts[0];
  const admin = accounts[1];
  const minter = accounts[2];
  const user1 = accounts[3];
  const user2 = accounts[4];

  beforeEach(async () => {
    gfToken = await GFToken.new(owner, { from: owner });
  });

  describe("Deployment", () => {
    it("should deploy with correct parameters", async () => {
      assert.equal(await gfToken.name(), "GoldFinger");
      assert.equal(await gfToken.symbol(), "GF");
      assert.equal(await gfToken.decimals(), 6);
      assert.equal(await gfToken.owner(), owner);
    });

    it("should have correct total supply cap", async () => {
      const expectedSupply = web3.utils.toBN("100000000000000000"); // 100B with 6 decimals
      assert.equal((await gfToken.TOTAL_SUPPLY()).toString(), expectedSupply.toString());
    });
  });

  describe("Access Control", () => {
    it("should allow owner to add admin", async () => {
      await gfToken.addAdmin(admin, { from: owner });
      assert.equal(await gfToken.isAdmin(admin), true);
    });

    it("should allow admin to add minter", async () => {
      await gfToken.addAdmin(admin, { from: owner });
      await gfToken.addMinter(minter, { from: admin });
      assert.equal(await gfToken.isMinter(minter), true);
    });

    it("should not allow non-admin to add minter", async () => {
      try {
        await gfToken.addMinter(minter, { from: user1 });
        assert.fail("Should have thrown error");
      } catch (error) {
        assert.include(error.message, "revert");
      }
    });
  });

  describe("Minting", () => {
    beforeEach(async () => {
      await gfToken.addAdmin(admin, { from: owner });
      await gfToken.addMinter(minter, { from: admin });
    });

    it("should allow minter to mint tokens", async () => {
      const mintAmount = web3.utils.toWei("1000", "mwei"); // 1000 GF (6 decimals)
      await gfToken.mint(user1, mintAmount, { from: minter });
      
      assert.equal((await gfToken.balanceOf(user1)).toString(), mintAmount);
      assert.equal((await gfToken.totalMinted()).toString(), mintAmount);
    });

    it("should not allow minting beyond total supply", async () => {
      const totalSupply = await gfToken.TOTAL_SUPPLY();
      
      try {
        await gfToken.mint(user1, totalSupply.add(web3.utils.toBN(1)), { from: minter });
        assert.fail("Should have thrown error");
      } catch (error) {
        assert.include(error.message, "revert");
      }
    });
  });

  describe("Blacklist", () => {
    beforeEach(async () => {
      await gfToken.addAdmin(admin, { from: owner });
      await gfToken.addMinter(minter, { from: admin });
      const mintAmount = web3.utils.toWei("1000", "mwei");
      await gfToken.mint(user1, mintAmount, { from: minter });
    });

    it("should allow admin to blacklist address", async () => {
      await gfToken.blacklist(user1, { from: admin });
      assert.equal(await gfToken.blacklisted(user1), true);
    });

    it("should prevent blacklisted address from transferring", async () => {
      await gfToken.blacklist(user1, { from: admin });
      
      try {
        await gfToken.transfer(user2, 100, { from: user1 });
        assert.fail("Should have thrown error");
      } catch (error) {
        assert.include(error.message, "revert");
      }
    });

    it("should prevent transfers to blacklisted address", async () => {
      await gfToken.blacklist(user2, { from: admin });
      
      try {
        await gfToken.transfer(user2, 100, { from: user1 });
        assert.fail("Should have thrown error");
      } catch (error) {
        assert.include(error.message, "revert");
      }
    });
  });

  describe("Pausable", () => {
    beforeEach(async () => {
      await gfToken.addAdmin(admin, { from: owner });
      await gfToken.addMinter(minter, { from: admin });
      const mintAmount = web3.utils.toWei("1000", "mwei");
      await gfToken.mint(user1, mintAmount, { from: minter });
    });

    it("should allow owner to pause contract", async () => {
      await gfToken.pause({ from: owner });
      assert.equal(await gfToken.paused(), true);
    });

    it("should prevent transfers when paused", async () => {
      await gfToken.pause({ from: owner });
      
      try {
        await gfToken.transfer(user2, 100, { from: user1 });
        assert.fail("Should have thrown error");
      } catch (error) {
        assert.include(error.message, "revert");
      }
    });

    it("should allow transfers after unpause", async () => {
      await gfToken.pause({ from: owner });
      await gfToken.unpause({ from: owner });
      
      await gfToken.transfer(user2, 100, { from: user1 });
      assert.equal((await gfToken.balanceOf(user2)).toString(), "100");
    });
  });
});