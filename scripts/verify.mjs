import { createHash } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import solc from "solc";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const MANIFEST_PATH = resolve(ROOT, "deployment/arc-mainnet-5042.json");
const EVIDENCE_PATH = resolve(ROOT, "evidence/latest.json");
const ZERO_WORD = "0x" + "00".repeat(32);

function sha256(value) {
  return createHash("sha256").update(value).digest("hex");
}

function fail(message) {
  throw new Error(message);
}

function cleanHex(value, label) {
  if (typeof value !== "string" || !/^0x[0-9a-f]*$/i.test(value) || value.length % 2 !== 0) {
    fail(`${label} is not even-length hex`);
  }
  return value.slice(2).toLowerCase();
}

function asWord(spec) {
  let value;
  if (spec.type === "address") {
    const address = cleanHex(spec.value, `${spec.name} address`);
    if (address.length !== 40) fail(`${spec.name} is not a 20-byte address`);
    value = BigInt(`0x${address}`);
  } else if (spec.type === "bool") {
    if (typeof spec.value !== "boolean") fail(`${spec.name} must be a JSON boolean`);
    value = spec.value ? 1n : 0n;
  } else if (/^uint\d+$/.test(spec.type)) {
    value = BigInt(spec.value);
    const bits = BigInt(spec.type.slice(4));
    if (value < 0n || value >= 1n << bits) fail(`${spec.name} does not fit ${spec.type}`);
  } else if (/^int\d+$/.test(spec.type)) {
    value = BigInt(spec.value);
    const bits = BigInt(spec.type.slice(3));
    const min = -(1n << (bits - 1n));
    const max = (1n << (bits - 1n)) - 1n;
    if (value < min || value > max) fail(`${spec.name} does not fit ${spec.type}`);
    if (value < 0n) value = (1n << 256n) + value;
  } else {
    fail(`unsupported immutable type ${spec.type} for ${spec.name}`);
  }
  return value.toString(16).padStart(64, "0");
}

function maskImmutables(runtimeHex, referenceGroups, label) {
  const bytes = Buffer.from(runtimeHex, "hex");
  for (const references of referenceGroups) {
    for (const reference of references) {
      const end = reference.start + reference.length;
      if (!Number.isInteger(reference.start) || !Number.isInteger(reference.length) || end > bytes.length) {
        fail(`${label} has an out-of-range immutable reference`);
      }
      bytes.fill(0, reference.start, end);
    }
  }
  return bytes.toString("hex");
}

function resolveImport(importPath) {
  const candidates = [
    resolve(ROOT, importPath),
    resolve(ROOT, "node_modules", importPath),
  ];
  for (const candidate of candidates) {
    if (existsSync(candidate)) return { contents: readFileSync(candidate, "utf8") };
  }
  return { error: `Import not found in the publication candidate: ${importPath}` };
}

function compile(manifest) {
  if (solc.version() !== manifest.compiler.version) {
    fail(`compiler version ${solc.version()} does not equal ${manifest.compiler.version}`);
  }

  const openZeppelinPackage = JSON.parse(
    readFileSync(resolve(ROOT, "node_modules/@openzeppelin/contracts/package.json"), "utf8"),
  );
  if (openZeppelinPackage.version !== manifest.compiler.openzeppelinVersion) {
    fail(
      `OpenZeppelin version ${openZeppelinPackage.version} does not equal ${manifest.compiler.openzeppelinVersion}`,
    );
  }

  const sources = {};
  for (const [sourcePath, expectedHash] of Object.entries(manifest.source.sourceFiles)) {
    const contents = readFileSync(resolve(ROOT, sourcePath));
    const actualHash = sha256(contents);
    if (actualHash !== expectedHash) fail(`${sourcePath} SHA-256 ${actualHash} does not equal ${expectedHash}`);
    sources[sourcePath] = { content: contents.toString("utf8") };
  }

  const input = {
    language: "Solidity",
    sources,
    settings: {
      evmVersion: manifest.compiler.evmVersion,
      optimizer: {
        enabled: manifest.compiler.optimizer,
        runs: manifest.compiler.optimizerRuns,
      },
      viaIR: manifest.compiler.viaIR,
      metadata: { bytecodeHash: manifest.compiler.bytecodeHash },
      remappings: manifest.compiler.remappings,
      outputSelection: {
        "*": {
          "*": [
            "evm.bytecode.object",
            "evm.deployedBytecode.object",
            "evm.deployedBytecode.immutableReferences",
          ],
        },
      },
    },
  };

  const output = JSON.parse(solc.compile(JSON.stringify(input), { import: resolveImport }));
  const errors = (output.errors ?? []).filter((entry) => entry.severity === "error");
  if (errors.length > 0) fail(errors.map((entry) => entry.formattedMessage).join("\n"));

  const artifacts = new Map();
  for (const contract of manifest.contracts) {
    const artifact = output.contracts?.[contract.source]?.[contract.artifact];
    if (!artifact) fail(`compiler did not emit ${contract.source}:${contract.artifact}`);
    const creation = artifact.evm?.bytecode?.object;
    const runtime = artifact.evm?.deployedBytecode?.object;
    if (!creation || !/^[0-9a-f]+$/i.test(creation)) fail(`${contract.name} creation bytecode is empty or unlinked`);
    if (!runtime || !/^[0-9a-f]+$/i.test(runtime)) fail(`${contract.name} runtime bytecode is empty or unlinked`);
    const immutableReferences = artifact.evm.deployedBytecode.immutableReferences ?? {};
    const referenceGroups = Object.entries(immutableReferences)
      .sort(([left], [right]) => Number(left) - Number(right))
      .map(([, references]) => references);
    if (referenceGroups.length !== contract.immutables.length) {
      fail(
        `${contract.name} compiler emitted ${referenceGroups.length} immutable declarations; manifest has ${contract.immutables.length}`,
      );
    }
    artifacts.set(contract.name, {
      creation: creation.toLowerCase(),
      runtime: runtime.toLowerCase(),
      referenceGroups,
    });
  }
  return { artifacts, input };
}

function makeRequests(manifest) {
  const requests = [
    { jsonrpc: "2.0", id: "chainId", method: "eth_chainId", params: [] },
    { jsonrpc: "2.0", id: "blockNumber", method: "eth_blockNumber", params: [] },
  ];
  for (const contract of manifest.contracts) {
    requests.push({
      jsonrpc: "2.0",
      id: `code:${contract.name}`,
      method: "eth_getCode",
      params: [contract.address, "latest"],
    });
    const transactionHash = contract.creation?.transactionHash ?? contract.creationEvidence?.transactionHash;
    if (transactionHash) {
      requests.push({
        jsonrpc: "2.0",
        id: `tx:${contract.name}`,
        method: "eth_getTransactionByHash",
        params: [transactionHash],
      });
    }
  }
  return requests;
}

async function queryProvider(provider, requests) {
  try {
    const response = await fetch(provider.url, {
      method: "POST",
      headers: { "Content-Type": "application/json", ...provider.headers },
      body: JSON.stringify(requests),
      signal: AbortSignal.timeout(30_000),
    });
    const body = await response.text();
    if (!response.ok) fail(`HTTP ${response.status}: ${body.slice(0, 300)}`);
    const parsed = JSON.parse(body);
    if (!Array.isArray(parsed)) fail(`provider did not return a JSON-RPC batch array: ${body.slice(0, 300)}`);
    const byId = new Map(parsed.map((entry) => [String(entry.id), entry]));
    const missing = requests.filter((request) => !byId.has(String(request.id)));
    if (missing.length > 0) fail(`provider omitted ${missing.length} JSON-RPC batch result(s)`);
    return { ok: true, responses: parsed, byId };
  } catch (error) {
    return { ok: false, error: error instanceof Error ? error.message : String(error), responses: [] };
  }
}

function rpcResult(providerResult, id) {
  if (!providerResult.ok) return { ok: false, error: providerResult.error };
  const entry = providerResult.byId.get(id);
  if (!entry) return { ok: false, error: "missing JSON-RPC result" };
  if (entry.error) return { ok: false, error: JSON.stringify(entry.error) };
  return { ok: true, value: entry.result };
}

function verifyContract(contract, artifact, providers, expectedChainId) {
  const failures = [];
  const deployedCodes = [];
  let immutableChecks = 0;
  let constructorChecks = 0;
  const compiledMasked = maskImmutables(artifact.runtime, artifact.referenceGroups, `${contract.name} compiler output`);

  for (const provider of providers) {
    const codeResult = rpcResult(provider.result, `code:${contract.name}`);
    if (!codeResult.ok) {
      failures.push(`${provider.name} eth_getCode: ${codeResult.error}`);
      continue;
    }
    let deployed;
    try {
      deployed = cleanHex(codeResult.value, `${provider.name} ${contract.name} runtime`);
    } catch (error) {
      failures.push(error.message);
      continue;
    }
    if (deployed.length === 0) {
      failures.push(`${provider.name} returned empty runtime`);
      continue;
    }
    deployedCodes.push({ provider: provider.name, code: deployed });
    if (deployed.length !== artifact.runtime.length) {
      failures.push(
        `${provider.name} runtime length ${deployed.length / 2} does not equal compiled ${artifact.runtime.length / 2}`,
      );
      continue;
    }
    const deployedMasked = maskImmutables(deployed, artifact.referenceGroups, `${provider.name} ${contract.name}`);
    if (deployedMasked !== compiledMasked) failures.push(`${provider.name} immutable-masked runtime differs`);

    for (let index = 0; index < artifact.referenceGroups.length; index += 1) {
      const immutable = contract.immutables[index];
      const expectedWord = asWord(immutable);
      for (const reference of artifact.referenceGroups[index]) {
        const actual = deployed.slice(reference.start * 2, (reference.start + reference.length) * 2);
        const expected = expectedWord.slice(expectedWord.length - reference.length * 2);
        if (actual !== expected) {
          failures.push(`${provider.name} immutable ${immutable.name} differs at byte ${reference.start}`);
        } else {
          immutableChecks += 1;
        }
      }
    }

    if (contract.creation) {
      const txResult = rpcResult(provider.result, `tx:${contract.name}`);
      if (!txResult.ok) {
        failures.push(`${provider.name} creation transaction: ${txResult.error}`);
      } else if (!txResult.value) {
        failures.push(`${provider.name} creation transaction was not found`);
      } else {
        const expectedInput = `0x${artifact.creation}${cleanHex(contract.creation.argumentsEncoded, "constructor arguments")}`;
        const actualInput = String(txResult.value.input ?? "").toLowerCase();
        if (txResult.value.to !== null) failures.push(`${provider.name} creation transaction has a non-null to address`);
        if (String(txResult.value.chainId ?? "").toLowerCase() !== `0x${expectedChainId.toString(16)}`) {
          failures.push(`${provider.name} creation transaction chainId differs`);
        }
        if (actualInput !== expectedInput) failures.push(`${provider.name} creation bytecode/constructor calldata differs`);
        else constructorChecks += 1;
      }
    } else if (contract.creationEvidence) {
      const txResult = rpcResult(provider.result, `tx:${contract.name}`);
      if (!txResult.ok) {
        failures.push(`${provider.name} parent transaction: ${txResult.error}`);
      } else if (!txResult.value) {
        failures.push(`${provider.name} parent transaction was not found`);
      } else {
        const actualTo = txResult.value.to === null ? null : String(txResult.value.to).toLowerCase();
        const expectedTo = contract.creationEvidence.parentAddress === null
          ? null
          : String(contract.creationEvidence.parentAddress).toLowerCase();
        const actualInput = String(txResult.value.input ?? "").toLowerCase();
        if (String(txResult.value.chainId ?? "").toLowerCase() !== `0x${expectedChainId.toString(16)}`) {
          failures.push(`${provider.name} parent transaction chainId differs`);
        }
        if (actualTo !== expectedTo) failures.push(`${provider.name} parent transaction destination differs`);
        if (sha256(actualInput) !== contract.creationEvidence.transactionInputSha256) {
          failures.push(`${provider.name} parent transaction input differs`);
        } else {
          constructorChecks += 1;
        }
      }
    }
  }

  if (deployedCodes.length === providers.length) {
    const first = deployedCodes[0].code;
    for (const deployed of deployedCodes.slice(1)) {
      if (deployed.code !== first) failures.push(`${deployed.provider} runtime differs from ${deployedCodes[0].provider}`);
    }
  }

  return {
    name: contract.name,
    address: contract.address,
    status: failures.length === 0 ? "MATCH" : "MISMATCH",
    runtimeBytes: artifact.runtime.length / 2,
    rpcRuntimeMatches: `${deployedCodes.length}/${providers.length}`,
    immutableReferenceMatches: immutableChecks,
    immutableReferenceTotal:
      artifact.referenceGroups.reduce((total, references) => total + references.length, 0) * providers.length,
    constructorMode: contract.creation ? "direct-creation-transaction" : contract.creationEvidence.kind,
    constructorMatches: contract.creation
      ? `${constructorChecks}/${providers.length}`
      : `parent=${constructorChecks}/${providers.length};immutables-only`,
    compiledRuntimeSha256: sha256(Buffer.from(artifact.runtime, "hex")),
    failures,
  };
}

async function main() {
  const manifestBytes = readFileSync(MANIFEST_PATH);
  const manifest = JSON.parse(manifestBytes);
  let compilation;
  try {
    compilation = compile(manifest);
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    for (const contract of manifest.contracts) {
      console.log(`MISMATCH ${contract.name} ${contract.address} | compile=${message.replaceAll("\n", " ")}`);
    }
    process.exitCode = 1;
    return;
  }

  const requests = makeRequests(manifest);
  const providers = await Promise.all(
    manifest.rpcs.map(async (provider) => ({
      name: provider.name,
      url: provider.url,
      result: await queryProvider(provider, requests),
    })),
  );

  for (const provider of providers) {
    if (!provider.result.ok) {
      console.log(`RPC ERROR ${provider.name} ${provider.url} | ${provider.result.error}`);
      continue;
    }
    const chainId = rpcResult(provider.result, "chainId");
    const block = rpcResult(provider.result, "blockNumber");
    const chainOkay = chainId.ok && Number.parseInt(chainId.value, 16) === manifest.chainId;
    console.log(
      `RPC ${chainOkay ? "MATCH" : "MISMATCH"} ${provider.name} | chainId=${chainId.ok ? chainId.value : chainId.error} block=${block.ok ? `${block.value} (${Number.parseInt(block.value, 16)})` : block.error}`,
    );
    if (!chainOkay) provider.result = { ok: false, error: "chainId mismatch", responses: provider.result.responses };
  }

  const results = manifest.contracts.map((contract) =>
    verifyContract(contract, compilation.artifacts.get(contract.name), providers, manifest.chainId),
  );

  for (const result of results) {
    const immutableSummary = `${result.immutableReferenceMatches}/${result.immutableReferenceTotal}`;
    console.log(
      `${result.status.padEnd(8)} ${result.name} ${result.address} | runtime=${result.rpcRuntimeMatches} immutables=${immutableSummary} constructor=${result.constructorMatches} bytes=${result.runtimeBytes}`,
    );
    for (const failure of result.failures) console.log(`         reason: ${failure}`);
  }

  const evidence = {
    capturedAt: new Date().toISOString(),
    manifest: "deployment/arc-mainnet-5042.json",
    manifestSha256: sha256(manifestBytes),
    compilerVersion: solc.version(),
    compilerSettings: compilation.input.settings,
    providers: providers.map((provider) => ({
      name: provider.name,
      url: provider.url,
      ok: provider.result.ok,
      error: provider.result.ok ? undefined : provider.result.error,
      responses: provider.result.responses,
    })),
    results,
  };
  mkdirSync(dirname(EVIDENCE_PATH), { recursive: true });
  writeFileSync(EVIDENCE_PATH, JSON.stringify(evidence, null, 2) + "\n");

  const matches = results.filter((result) => result.status === "MATCH").length;
  const status = matches === results.length ? "MATCH" : "MISMATCH";
  console.log(`RESULT ${status} ${matches}/${results.length} contracts; evidence=${EVIDENCE_PATH}`);
  if (status !== "MATCH") process.exitCode = 1;
}

await main();
