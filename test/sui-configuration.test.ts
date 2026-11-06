// Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: Apache-2.0
//
// Runs inside an aws-blockchain-node-runners checkout with this blueprint
// installed (see scripts/validate.sh): copied to test/integration/.

import * as fs from 'fs';
import * as path from 'path';
import { execFileSync } from 'child_process';
import { ConfigurationLoader } from '../../lib/core/configuration-loader';
import { DeploymentMode } from '../../lib/interfaces/enums';

const BLUEPRINT = path.join(process.cwd(), 'node_modules', 'aws-bnr-blueprint-sui');
const CONFIG_RE = /^sui-node-(v\d+\.\d+\.\d+)-full\.sh$/;

// Configuration pinned per network. scripts/bump.sh rewrites these lines.
const PINNED: Record<string, string> = {
    mainnet: 'sui-node-v1.83.1-full.sh',
    testnet: 'sui-node-v1.83.1-full.sh',
};

const SAMPLES: Array<{ file: string; network: string; mode: DeploymentMode; cpu: string; config: string }> = [
    { file: '.env-mainnet-sui-node-full', network: 'mainnet', mode: DeploymentMode.SINGLE_NODE, cpu: 'x86_64', config: PINNED.mainnet },
    { file: '.env-mainnet-sui-node-full-arm64', network: 'mainnet', mode: DeploymentMode.SINGLE_NODE, cpu: 'ARM_64', config: PINNED.mainnet },
    { file: '.env-mainnet-sui-node-full-ha', network: 'mainnet', mode: DeploymentMode.HA_NODES, cpu: 'x86_64', config: PINNED.mainnet },
    { file: '.env-testnet-sui-node-full', network: 'testnet', mode: DeploymentMode.SINGLE_NODE, cpu: 'x86_64', config: PINNED.testnet },
    { file: '.env-testnet-sui-node-full-ha', network: 'testnet', mode: DeploymentMode.HA_NODES, cpu: 'x86_64', config: PINNED.testnet },
];

describe('Sui Protocol Configuration', () => {
    let configLoader: ConfigurationLoader;

    beforeEach(() => {
        configLoader = new ConfigurationLoader('blueprints');
    });

    describe('Protocol Configuration', () => {
        it('should load the Sui protocol configuration', () => {
            const protocolConfig = configLoader.loadProtocolConfig('sui');

            expect(protocolConfig.BLOCKCHAIN_PROTOCOL).toBe('sui');
            expect(protocolConfig.supportedDeploymentModes).toEqual([DeploymentMode.SINGLE_NODE, DeploymentMode.HA_NODES]);
            expect(protocolConfig.BC_NETWORKS).toEqual(['mainnet', 'testnet']);
            expect(protocolConfig.customEnvVarsNamePrefix).toBe('SUI');
        });

        it('should only list well-formed configuration names', () => {
            const protocolConfig = configLoader.loadProtocolConfig('sui');

            expect(protocolConfig.availableConfigurations.map(c => c.name)).toContain(protocolConfig.defaultConfiguration);
            protocolConfig.availableConfigurations.forEach(c => expect(c.name).toMatch(CONFIG_RE));
        });

        // Keeps package.json, samples and configuration files in step after a
        // version bump (scripts/bump.sh): no stale or missing configurations.
        it('should list exactly the pinned configurations, defaulting to mainnet', () => {
            const protocolConfig = configLoader.loadProtocolConfig('sui');
            const pinned = [...new Set(Object.values(PINNED))].sort();
            const shipped = fs.readdirSync(path.join(BLUEPRINT, 'configurations')).filter(f => CONFIG_RE.test(f)).sort();

            expect(Object.keys(PINNED).sort()).toEqual([...protocolConfig.BC_NETWORKS].sort());
            expect(protocolConfig.availableConfigurations.map(c => c.name).sort()).toEqual(pinned);
            expect(shipped).toEqual(pinned);
            expect(protocolConfig.defaultConfiguration).toBe(PINNED.mainnet);
        });

        it('should keep RPC VPC-internal and open only P2P publicly', () => {
            const protocolConfig = configLoader.loadProtocolConfig('sui');
            const byPort = Object.fromEntries(protocolConfig.requiredPorts.map(p => [p.port, p]));

            expect(Object.keys(byPort).map(Number).sort()).toEqual([8084, 9000]);
            expect(byPort[9000]).toMatchObject({ protocol: 'tcp', public: false });
            expect(byPort[8084]).toMatchObject({ protocol: 'udp', public: true });
            // Metrics (9184) and admin (1337) are host-local and never opened.
            expect(protocolConfig.requiredPorts.some(p => p.port === 9184 || p.port === 1337)).toBe(false);
        });

        it('should health-check the sui-node /health endpoint', () => {
            const protocolConfig = configLoader.loadProtocolConfig('sui');

            expect(protocolConfig.monitoring.healthCheckPath).toBe('/health');
        });
    });

    describe.each(SAMPLES)('Sample $file', ({ file, network, mode, cpu, config }) => {
        const envPath = path.join(BLUEPRINT, 'samples', file);

        it('should load with the expected network, mode, CPU and configuration', () => {
            const envConfig = configLoader.loadEnvironmentConfig(envPath);

            expect(envConfig.BLOCKCHAIN_PROTOCOL).toBe('sui');
            expect(envConfig.BC_NETWORK).toBe(network);
            expect(envConfig.DEPLOYMENT_MODE).toBe(mode);
            expect(envConfig.CPU_TYPE).toBe(cpu);
            expect(envConfig.CLIENT_CONFIG).toBe(config);
        });

        it('should pass configuration validation apart from the account ID placeholder', () => {
            // The stand-in ID is built at runtime so git-secrets does not flag a literal.
            const envConfig = configLoader.loadEnvironmentConfig(envPath);
            const result = configLoader.validateConfiguration({ ...envConfig, AWS_ACCOUNT_ID: '1'.repeat(12) });

            expect(result.errors).toEqual([]);
            expect(result.isValid).toBe(true);
        });

        it('should put /data on NVMe instance store sized for Sui', () => {
            const envConfig = configLoader.loadEnvironmentConfig(envPath);
            const dataVol = envConfig.DATA_VOLUMES.find(v => v.MOUNT_PATH === '/data');

            expect(dataVol).toBeDefined();
            expect(dataVol!.TYPE).toBe('instance-store');
            expect(dataVol!.SIZE).toBeGreaterThanOrEqual(3500);
        });

        it('should restore a formal snapshot by default', () => {
            const envConfig = configLoader.loadEnvironmentConfig(envPath);

            expect(envConfig.SNAPSHOT_ENABLED).toBe(true);
        });
    });

    describe.each(['.env-mainnet-sui-node-full-ha', '.env-testnet-sui-node-full-ha'])('HA sample %s', (haFile) => {
        it('should only route traffic to synced, indexed nodes', () => {
            const envConfig = configLoader.loadEnvironmentConfig(path.join(BLUEPRINT, 'samples', haFile));

            expect(configLoader.validateHAConfigVariables(envConfig).isValid).toBe(true);
            expect(envConfig.HA_CONFIG!.HA_ALB_HEALTHCHECK_PORT).toBe(9000);
            // Plain /health on purpose (ADR-0023): with ?threshold_seconds the ASG,
            // which uses ELB health checks, would replace every node during a
            // network-wide Sui halt. Lag is covered by the c1_seconds_behind alarm.
            expect(envConfig.HA_CONFIG!.HA_ALB_HEALTHCHECK_PATH).toBe('/health');
            expect(envConfig.HA_CONFIG!.HA_ALB_HEALTHCHECK_HTTP_CODES).toBe('200');
            // Testnet deploy-to-healthy measured 3h43m (2026-11-03); mainnet is
            // longer. A short grace period makes the ASG replace bootstrapping nodes.
            expect(envConfig.HA_CONFIG!.HA_ALB_HEALTHCHECK_GRACE_PERIOD_MIN).toBeGreaterThanOrEqual(600);
            // AWS maximum lifecycle-hook heartbeat is 7200 s.
            expect(envConfig.HA_CONFIG!.HA_NODES_HEARTBEAT_DELAY_MIN).toBeLessThanOrEqual(120);
        });

        // ADR-0024: 3 nodes keep a spare during rolling upgrades and replacements.
        it('should run 3 nodes', () => {
            const envConfig = configLoader.loadEnvironmentConfig(path.join(BLUEPRINT, 'samples', haFile));

            expect(envConfig.HA_CONFIG!.HA_NUMBER_OF_NODES).toBe(3);
        });
    });

    describe('Blueprint files', () => {
        it('should ship the required files', () => {
            ['package.json', 'README.md', 'LICENSE', 'user-data/node.sh', 'user-data/syncchecker.sh',
             'user-data/common/install-sui-binaries.sh', 'user-data/common/write-fullnode-config.sh',
             'user-data/common/download-snapshot.sh', 'user-data/common/sui-version.sh'].forEach(f => {
                expect(fs.existsSync(path.join(BLUEPRINT, f))).toBe(true);
            });
        });

        // ADR-0022: after an in-place upgrade, a setup re-run with the stack's
        // older CLIENT_CONFIG must keep the newer release. Runs the real helper.
        it('should never downgrade an in-place upgraded node unless allowed', () => {
            const helper = path.join(BLUEPRINT, 'user-data', 'common', 'sui-version.sh');
            const decide = (requested: string, network: string, marker: string, allow: string): string => {
                try {
                    const out = execFileSync('bash', ['-c', `. "$1"; sui_keep_newer_installed "$2" "$3" "$4" "$5"`,
                        'test', helper, requested, network, marker, allow], { encoding: 'utf8' });
                    return `keep:${out.trim()}`;
                } catch {
                    return 'install';
                }
            };
            const m = 'sui-mainnet-v1.84.0-ubuntu-x86_64.tgz';

            expect(decide('v1.83.1', 'mainnet', m, 'false')).toBe('keep:v1.84.0');
            expect(decide('v1.84.0', 'mainnet', m, 'false')).toBe('install');
            expect(decide('v1.85.0', 'mainnet', m, 'false')).toBe('install');
            expect(decide('v1.83.1', 'testnet', m, 'false')).toBe('install');
            expect(decide('v1.83.1', 'mainnet', m, 'true')).toBe('install');
            expect(decide('v1.83.1', 'mainnet', '', 'false')).toBe('install');
            expect(decide('v1.83.1', 'mainnet', 'not-a-marker', 'false')).toBe('install');
            expect(decide('v1.84.9', 'mainnet', 'sui-mainnet-v1.84.10-ubuntu-aarch64.tgz', 'false')).toBe('keep:v1.84.10');
        });

        it('should apply the safeguard in the installer and validate SUI_ALLOW_DOWNGRADE', () => {
            const protocolConfig = configLoader.loadProtocolConfig('sui');
            const installer = fs.readFileSync(path.join(BLUEPRINT, 'user-data', 'common', 'install-sui-binaries.sh'), 'utf8');

            expect(protocolConfig.customEnvVars).toContain('SUI_ALLOW_DOWNGRADE=false');
            expect(installer).toContain('sui-version.sh');
            expect(installer).toContain('sui_keep_newer_installed "$SUI_VERSION" "$BC_NETWORK"');
            expect(installer).toMatch(/true\|false\) ;;/);
            SAMPLES.forEach(s => {
                const env = fs.readFileSync(path.join(BLUEPRINT, 'samples', s.file), 'utf8');
                expect(env).toMatch(/^SUI_ALLOW_DOWNGRADE="false"$/m);
            });
        });

        // ADR-0023: one lag alarm per stack needs a series shared by all nodes.
        it('should publish a stack-level c1_seconds_behind for the lag alarm', () => {
            const checker = fs.readFileSync(path.join(BLUEPRINT, 'user-data', 'syncchecker.sh'), 'utf8');

            expect(checker).toContain('--dimensions "StackName=$STACK_NAME"');
            expect(checker).toMatch(/METRICS_OK" = "true" \] && \[ -n "\$\{STACK_NAME:-\}" \]/);
        });

        it('should have an identical script for every available configuration', () => {
            const protocolConfig = configLoader.loadProtocolConfig('sui');
            const normalize = (s: string) => s.replace(/v\d+\.\d+\.\d+/g, 'vX').replace(/(mainnet|testnet)-vX/g, 'NET-vX');
            const bodies = protocolConfig.availableConfigurations.map(c =>
                normalize(fs.readFileSync(path.join(BLUEPRINT, 'configurations', c.name), 'utf8')));

            bodies.forEach(b => expect(b).toBe(bodies[0]));
        });

        it('should bind RPC to the internal IP and metrics to loopback', () => {
            const writer = fs.readFileSync(path.join(BLUEPRINT, 'user-data', 'common', 'write-fullnode-config.sh'), 'utf8');

            expect(writer).toMatch(/^json-rpc-address: "\$\{EC2_INTERNAL_IP\}:\$\{RPC_PORT\}"$/m);
            expect(writer).toMatch(/^metrics-address: "127\.0\.0\.1:\$\{METRICS_PORT\}"$/m);
            expect(writer).toMatch(/^network-address: "\/ip4\/127\.0\.0\.1\/tcp\/8080\/http"$/m);
            expect(writer).toMatch(/listen-address: "0\.0\.0\.0:\$\{P2P_PORT\}"/);
        });

        it('should run the node service as bcuser under the name "node"', () => {
            const nodeSh = fs.readFileSync(path.join(BLUEPRINT, 'user-data', 'node.sh'), 'utf8');

            expect(nodeSh).toContain('/etc/systemd/system/node.service');
            expect(nodeSh).toMatch(/^User=bcuser$/m);
            expect(nodeSh).toMatch(/^EnvironmentFile=\/etc\/cdk_environment$/m);
            expect(nodeSh).toContain('touch /data/init-completed');
        });

        // Regression (issue 2, redeploy test 2026-11-03): after a stop/start the
        // enabled service started before /data was mounted and crash-looped.
        it('should not start the node service unless /data is mounted', () => {
            const nodeSh = fs.readFileSync(path.join(BLUEPRINT, 'user-data', 'node.sh'), 'utf8');
            const unit = nodeSh.slice(nodeSh.indexOf('[Unit]'), nodeSh.indexOf('[Service]'));

            expect(unit).toMatch(/^RequiresMountsFor=\/data$/m);
            expect(unit).toMatch(/^ConditionPathIsMountPoint=\/data$/m);
        });

        // Regression (issue 3, 2026-11-03): `list-unit-files | grep -q` under
        // pipefail fails at random with SIGPIPE, so shaping was never enabled.
        it('should detect net-rules.service without a pipefail-unsafe grep -q pipe', () => {
            const checker = fs.readFileSync(path.join(BLUEPRINT, 'user-data', 'syncchecker.sh'), 'utf8');

            expect(checker).not.toMatch(/^\s*if[^\n]*list-unit-files[^\n]*\|\s*grep -q/m);
            expect(checker).toContain('systemctl cat net-rules.service');
        });

        // Regression (issue 1, live test 2026-11-03): the framework starts
        // net-rules.service during setup regardless of TRAFFIC_SHAPING_ENABLED,
        // and the snapshot restore timed out twice with shaping on.
        it('should stop traffic shaping before the install phase', () => {
            const nodeSh = fs.readFileSync(path.join(BLUEPRINT, 'user-data', 'node.sh'), 'utf8');
            const stopAt = nodeSh.indexOf('systemctl stop net-rules.service');
            const installAt = nodeSh.indexOf('"$CONFIG_SCRIPT" install');

            expect(stopAt).toBeGreaterThan(-1);
            expect(installAt).toBeGreaterThan(stopAt);
        });

        it('should keep shaping off during bootstrap and when shaping is disabled', () => {
            const checker = fs.readFileSync(path.join(BLUEPRINT, 'user-data', 'syncchecker.sh'), 'utf8');
            const initBlock = checker.slice(checker.indexOf('if [ ! -f /data/init-completed ]'), checker.indexOf('exit 0', checker.indexOf('if [ ! -f /data/init-completed ]')));
            const disabledBlock = checker.slice(checker.indexOf('if [ "$TRAFFIC_SHAPING_ENABLED" != "true" ]'));

            expect(initBlock).toContain('shaping_off');
            expect(disabledBlock.slice(0, disabledBlock.indexOf('fi'))).toContain('shaping_off');
        });

        it('should pass validated snapshot tuning settings to sui-tool', () => {
            const protocolConfig = configLoader.loadProtocolConfig('sui');
            const snapshot = fs.readFileSync(path.join(BLUEPRINT, 'user-data', 'common', 'download-snapshot.sh'), 'utf8');

            expect(protocolConfig.customEnvVars).toEqual(expect.arrayContaining(['SUI_SNAPSHOT_MAX_RETRIES=10', 'SUI_SNAPSHOT_PARALLEL_DOWNLOADS=50']));
            expect(snapshot).toContain('--max-retries "$MAX_RETRIES"');
            expect(snapshot).toContain('--num-parallel-downloads "$PARALLEL_DOWNLOADS"');
            expect(snapshot).toMatch(/\[ "\$PARALLEL_DOWNLOADS" -gt 200 \]/);
        });
    });
});
