// migrations/3_deploy_upgradeable_box.js
const TransparentUpgradeableProxy = artifacts.require('TransparentUpgradeableProxy');
const ProxyAdmin = artifacts.require('ProxyAdmin');
const PlanetNFT = artifacts.require('PlanetNFT');
const Marketplace = artifacts.require('Marketplace');
// const PlanetNFTsV2 = artifacts.require('PlanetNFTsV2');

module.exports = async function (deployer) {
  await deployer.deploy(PlanetNFT);
  const planetNFTs = await PlanetNFT.deployed();
  await deployer.deploy(ProxyAdmin);
  const proxyAdmin = await ProxyAdmin.deployed();
  await deployer.deploy(TransparentUpgradeableProxy, planetNFTs.address, proxyAdmin.address, []);
  const trans = await TransparentUpgradeableProxy.deployed();
  const proxyPlanet = await PlanetNFT.at(trans.address);
  await proxyPlanet.initialize();
  // await deployer.deploy(MarketplaceAdmin);
  // const protocolAdmin = await MarketplaceAdmin.deployed();
  await deployer.deploy(Marketplace);
  const marketplace = await Marketplace.deployed();
  // await deployer.deploy(PlanetNFTsV2);
  // const planetNFTsV2 = await PlanetNFTsV2.deployed();
  // await planetNFTsV2.initialize();
  // console.log(planetNFTsV2.address);
};
