/* App-owned, camera-free database maintenance. Recognition code stays bundled. */
(() => {
  let running = false;
  const empty = status => ({ status, downloadedBytes: 0, cachedShards: 0 });
  async function run(config) {
    if (running || !config || !['tcgp:1', 'tcgp:2', 'tcgp:3'].includes(config.game) ||
        typeof config.cacheToken !== 'string' || config.cacheToken.length < 32 || config.cacheToken.length > 256 ||
        globalThis.location?.origin !== 'http://127.0.0.1:18764') return empty('failed');
    running = true;
    globalThis.CardShowNativeCache = { token: config.cacheToken };
    try {
      const packs = await import('/newscanplus/assets/js/core/pack.js');
      const result = await packs.prepareCachedPackUpdate(config.game);
      if (!result || !['updated', 'upToDate', 'skipped'].includes(result.status) ||
          !Number.isSafeInteger(result.downloadedBytes) || result.downloadedBytes < 0 || result.downloadedBytes > 10_000_000_000 ||
          !Number.isSafeInteger(result.cachedShards) || result.cachedShards < 0 || result.cachedShards > 8192) return empty('failed');
      if (result.status === 'skipped') return empty('skipped');
      for (const key of ['proposedManifestPath', 'previousManifestPath']) {
        const path = result[key];
        if (typeof path !== 'string' || path.length > 512 || !/^[A-Za-z0-9][A-Za-z0-9_./-]*$/.test(path) ||
            path.split('/').some(part => !part || part === '.' || part === '..')) return empty('failed');
      }
      return { status: result.status, downloadedBytes: result.downloadedBytes, cachedShards: result.cachedShards,
        proposedManifestPath: result.proposedManifestPath, previousManifestPath: result.previousManifestPath };
    } catch {
      return empty('failed');
    } finally {
      running = false;
    }
  }
  globalThis.CardShowDatabaseUpdater = { run };
})();
