// `t2 agent create` — the composition umbrella (T1/A2, SPEC_COMPOSITION_MOMENT
// §4): ensure a wallet (generate if the path is empty, reuse if not) →
// register the Agent ID (idempotent, sponsored) → set the display profile
// (name · description · category). One command from nothing to a named,
// listed agent. (`--owner` was removed in S.1032 — ownership left the
// product; agents are autonomous Agent IDs.) Unlike `t2 init`'s
// best-effort register, create is explicitly an online command — failures
// are loud.

import type { Command } from 'commander';
import {
  generateKeypair,
  hasLimits,
  saveKey,
  setLimits,
  walletExists,
} from '@t2000/sdk';
import { AGENT_CATEGORIES, parseCategory } from '../../lib/agent-category.js';
import { registerWallet } from '../../lib/agent-register.js';
import { commerceFor } from '../../lib/commerce-client.js';
import { withAgent } from '../../lib/with-agent.js';
import {
  handleError,
  isJsonMode,
  printBlank,
  printJson,
  printKeyValue,
  printLine,
  printSuccess,
} from '../../output.js';

const DEFAULT_API_BASE = process.env.T2000_API_URL ?? 'https://api.t2000.ai/v1';
const STORE_BASE = 'https://t2000.ai';


// Fresh wallets seed the same conservative defaults as `t2 init` (2.2 —
// limits ON by default).
const DEFAULT_PER_TX_USD = 25;
const DEFAULT_DAILY_USD = 100;

export interface AgentCreateOptions {
  name: string;
  description?: string;
  category?: string;
  key?: string;
  api?: string;
}

export function registerAgentCreate(group: Command) {
  group
    .command('create')
    .description(
      'Create an agent in one pass — wallet + on-chain Agent ID + profile. Sponsored, gasless.',
    )
    .requiredOption('--name <name>', 'Display name (shown in the store)')
    .option('--description <text>', 'Short description (what it does, for whom)')
    .option(
      '--category <category>',
      `Directory category: ${AGENT_CATEGORIES.join(' | ')}`,
    )
    .option('--key <path>', 'Custom wallet path (default ~/.t2000/wallet.key)')
    .option('--api <url>', `API base URL (default ${DEFAULT_API_BASE})`)
    .action(async (opts: AgentCreateOptions) => {
      try {
        const base = opts.api ?? DEFAULT_API_BASE;
        const name = opts.name.trim();
        if (!name) {
          throw new Error('--name must not be empty.');
        }
        if (name.length > 60) {
          throw new Error('--name must be 60 characters or fewer.');
        }

        let category: string | undefined;
        if (opts.category !== undefined) {
          category = parseCategory(opts.category);
        }

        // 1. Wallet — reuse the file if present (create "dresses" an existing
        // wallet; register is idempotent), otherwise generate + seed limits.
        const created = !(await walletExists(opts.key));
        if (created) {
          const keypair = generateKeypair();
          await saveKey(keypair, undefined, opts.key);
          if (!hasLimits()) {
            setLimits({
              perTxUsd: DEFAULT_PER_TX_USD,
              dailyUsd: DEFAULT_DAILY_USD,
            });
          }
        }
        const agent = await withAgent({ keyPath: opts.key });
        const address = agent.address();

        // 2. Register (sponsored; idempotent when already on-chain).
        const reg = await registerWallet({
          keypair: agent.keypair,
          address,
          base,
        });

        // 3. Profile — signed challenge, no gas (SDK commerce SSOT, S.1158).
        await commerceFor(agent, base).updateProfile({
          name,
          description: opts.description,
          category,
        });

        const storeUrl = `${STORE_BASE}/${address}`;
        if (isJsonMode()) {
          printJson({
            address,
            walletCreated: created,
            registered: true,
            alreadyRegistered: reg.alreadyRegistered,
            name,
            ...(category ? { category } : {}),
            storeUrl,
            keyPath: opts.key ?? '~/.t2000/wallet.key',
          });
          return;
        }

        printBlank();
        printSuccess(`${name} is live`);
        printKeyValue('Address', address);
        printKeyValue('Store', storeUrl);
        printKeyValue(
          'Wallet',
          created
            ? `created at ${opts.key ?? '~/.t2000/wallet.key'}`
            : `reused ${opts.key ?? '~/.t2000/wallet.key'}`,
        );
        printBlank();
        printLine('Next:');
        printLine('  t2 fund                      # add USDC (QR / card link)');
        printLine('  npx skills add t2000-afi/t2000-skills   # optional playbooks');
        printBlank();
      } catch (error) {
        handleError(error);
      }
    });
}
