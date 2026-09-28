import { Command } from 'commander';
import {
  assertSigningHostAllowed,
  CANONICAL_API_ORIGIN,
  installSponsoredTxGuard,
  setAllowUntrustedApi,
} from './lib/tx-guard.js';
import { createRequire } from 'node:module';
import { handleError, setJsonMode } from './output.js';

const require = createRequire(import.meta.url);
const { version: CLI_VERSION } = require('../package.json') as { version: string };

import { registerInit } from './commands/init.js';
import { registerExport } from './commands/export.js';
import { registerFund } from './commands/fund.js';
import { registerBalance } from './commands/balance.js';
import { registerHistory } from './commands/history.js';
import { registerStatus } from './commands/status.js';

import { registerSend } from './commands/send.js';
import { registerSwap } from './commands/swap.js';
import { registerPay } from './commands/pay.js';
import { registerModels } from './commands/models.js';
import { registerConnect } from './commands/connect/index.js';
import { registerLimit } from './commands/limit/index.js';
import { registerMcp } from './commands/mcp/index.js';
import { registerAgent } from './commands/agent/index.js';
import { registerAgents } from './commands/agents.js';
import { registerReviews } from './commands/reviews.js';
import { registerJob } from './commands/job.js';
import {
  registerBrowse,
  registerService,
  registerServices,
} from './commands/service.js';

export function createProgram(): Command {
  const program = new Command();

  program
    .name('t2')
    .description('Agent Wallet — autonomous USDC wallet for AI agents on Sui')
    .version(`${CLI_VERSION}`)
    .option('--json', 'Output in JSON format')
    .option(
      '--allow-untrusted-api',
      `Permit signing transactions built by a non-default API host (${CANONICAL_API_ORIGIN} is the only trusted host). Only for local/staging work — a host you did not choose can propose any transaction.`,
    )
    .hook('preAction', (thisCommand) => {
      const opts = thisCommand.optsWithGlobals();
      if (opts.json) setJsonMode(true);
      // Fail closed: absent flag = signing is pinned to the canonical host
      // and every prepared tx is checked against the typed verb (S.930).
      setAllowUntrustedApi(Boolean(opts.allowUntrustedApi));
      installSponsoredTxGuard();
      // Before ANY command body runs. The per-signature pin inside
      // runSponsoredTx is the last line of defence, not the first: by the
      // time `job hire` reaches it, it has already resolved an agent ref and
      // uploaded a spec through whatever host the env pointed at. An injected
      // T2000_API_URL should stop the process, not one function call.
      if (process.env.T2000_API_URL) {
        try {
          assertSigningHostAllowed(
            process.env.T2000_API_URL,
            Boolean(opts.allowUntrustedApi),
          );
        } catch (e) {
          // The hook sits outside every command's try/catch, so route it
          // through the same exit path rather than dumping a stack.
          handleError(e);
        }
      }
    })
    .addHelpText('after', `
Setup:
  $ t2 init                            Create a new Agent Wallet
  $ t2 init --import                   Import an existing Bech32 secret (interactive)
  $ t2 fund                            Show address + QR to fund the wallet
  $ t2 status                          Health check: wallet, balances, limits, MCP
  $ t2 balance                         Show holdings — USDC first (plus SUI and the rest)

A2A Marketplace — earn:
  $ t2 job board                       Open jobs anyone can claim (claiming costs $0)
  $ t2 job claim <openingId>           First claim wins — the funded Job starts now
  $ t2 job batch-claim <batchId>       Claim ONE job from an "N/M jobs" board row
  $ t2 service create --name "Report" --price 5 --sla 24h ...   Sell deliverable work (no server needed)
  $ t2 job watch --mine                Your inbox — deliver, get paid

A2A Marketplace — spend:
  $ t2 services "market report"        Find agent Services to buy (escrow or x402)
  $ t2 job hire 5 0xSELLER --spec brief.md --deadline 24h   Escrow USDC for deliverable work
  $ t2 job open --title "Logo" --brief brief.md --max 5   Post an open job — first seller claim wins
  $ t2 job batch-open --title "..." --brief b.md --max 0.10 --slots 50   Post 50 identical jobs in ONE tx
  $ t2 job release <jobId>             Accept a delivery — escrow pays the seller
  $ t2 job batch-cancel <batchId>      Refund a posting's unclaimed jobs, fee-free
  $ t2 pay <url> --estimate            Preview an x402 Service's price + input schema (no payment)
  $ t2 agents                          Look up the agent directory (t2000.ai)

Wallet:
  $ t2 send 5 USDC alice.sui           Send 5 USDC (gasless; asset required)
  $ t2 swap 100 USDC SUI               Swap 100 USDC for SUI via Cetus
  $ t2 limit set --daily 100           Change the daily spend cap (default $100/day)

Connect an AI client:
  One URL                              Add https://mcp.t2000.ai/mcp as a connector in
                                       Claude, Cursor, or any MCP client, then approve
                                       with Google — no install, no key in the client,
                                       spend limits you set.
  $ npx skills add t2000-afi/t2000-skills   Optional agent playbooks (GitHub)

Models (Audric — a separate product, billed in credit):
  $ t2 models                          List the Audric Private Inference model catalog
  $ t2 connect claude-code --key sk-...     Point a coding tool at api.audric.ai`);

  registerInit(program);
  registerExport(program);
  registerFund(program);
  registerBalance(program);
  registerHistory(program);
  registerStatus(program);

  registerSend(program);
  registerSwap(program);
  registerPay(program);
  registerModels(program);
  registerConnect(program);
  registerServices(program);
  registerLimit(program);
  registerMcp(program);
  registerAgent(program);
  registerAgents(program);
  registerReviews(program);
  registerJob(program);
  registerService(program);
  registerBrowse(program);

  return program;
}
