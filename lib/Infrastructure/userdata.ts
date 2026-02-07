import * as ec2 from 'aws-cdk-lib/aws-ec2';
//import * as iam from 'aws-cdk-lib/aws-iam';
import * as s3Assets from 'aws-cdk-lib/aws-s3-assets';

import path from 'path';
import { fileURLToPath } from 'url';
import * as cdk from 'aws-cdk-lib';
import { Stack } from 'aws-cdk-lib';

import { type UbuntuInstanceProps } from './ec2-instance.ts';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

export class CustomUbuntuUserData {
  public init: ec2.CloudFormationInit;

  public initOptions: ec2.ApplyCloudFormationInitOptions;

  public prefix_bin_asset: s3Assets.Asset;

  public prefix_etc_asset: s3Assets.Asset;

  public ssh_keys_asset: s3Assets.Asset;

  public shellCommands: ec2.UserData;

  private mode_to_stage = (mode: string) => {
    if(!mode.localeCompare('dev')){
      return 'development';
    }
    if(!mode.localeCompare('prod')){
      return 'production';
    }
    return 'test';
  };

  public constructor(
    stack: Stack,
    props: UbuntuInstanceProps,
    hostname: string,
  ) {
    // Add timestamp to force asset rebuild on every deploy
    const deployTimestamp = Date.now().toString();
    
    this.prefix_bin_asset = new s3Assets.Asset(stack, 'prefixBinAsset', {
      path: path.join(__dirname, './prefixBin'),
    });

    this.prefix_etc_asset = new s3Assets.Asset(stack, 'prefix_etc_asset', {
      path: path.join(__dirname, './etc'),
    });

    this.ssh_keys_asset = new s3Assets.Asset(stack, 'sshKeysAsset', {
      path: path.join(__dirname, './ssh_keys/authorized_keys'),
    });

    this.shellCommands = ec2.UserData.forLinux();
    this.shellCommands.addCommands(
      'set -ex',
      'apt-get update',
      'apt-get install -y python3-pip unzip curl',
      'pip3 install --break-system-packages https://s3.amazonaws.com/cloudformation-examples/aws-cfn-bootstrap-py3-latest.tar.gz',
      'mkdir -p /opt/aws/bin',
      'ln -sf /usr/local/bin/cfn-* /opt/aws/bin/',
      'curl "https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip" -o "awscliv2.zip"',
      'unzip -qq awscliv2.zip',
      './aws/install',
    );

    // S3 downloads moved to cfn-init (downloadAssets config) to avoid credential timing issues
    // These paths are where cfn-init will download the assets
    const local_bin_path = '/tmp/prefix_bin.zip';
    const local_etc_path = '/tmp/prefix_etc.zip';
    const local_ssh_keys_path = '/tmp/authorized_keys';

    this.init = ec2.CloudFormationInit.fromConfigSets({
      configSets: {
        default: [
          'downloadAssets',
          'installPackages',
          'createUsers',
          'configureSSM',
          'configureApp',
        ],
      },
      configs: {
        downloadAssets: new ec2.InitConfig([
          // Download assets from S3 using cfn-init (handles IAM auth properly)
          ec2.InitFile.fromS3Object(
            local_bin_path,
            this.prefix_bin_asset.bucket,
            this.prefix_bin_asset.s3ObjectKey,
          ),
          ec2.InitFile.fromS3Object(
            local_etc_path,
            this.prefix_etc_asset.bucket,
            this.prefix_etc_asset.s3ObjectKey,
          ),
          ec2.InitFile.fromS3Object(
            local_ssh_keys_path,
            this.ssh_keys_asset.bucket,
            this.ssh_keys_asset.s3ObjectKey,
          ),
        ]),
        installPackages: new ec2.InitConfig([
          ec2.InitCommand.shellCommand('add-apt-repository -y universe'),
          ec2.InitCommand.shellCommand('apt-get update'),
          ec2.InitCommand.shellCommand('apt-get dist-upgrade -y'),
          ec2.InitPackage.apt('at'),
          ec2.InitPackage.apt('autoconf'),
          ec2.InitPackage.apt('autoconf-archive'),
          ec2.InitPackage.apt('automake'),
          ec2.InitPackage.apt('bison'),
          ec2.InitPackage.apt('build-essential'),
          ec2.InitPackage.apt('certbot'),
          ec2.InitPackage.apt('curl'),
          ec2.InitPackage.apt('flex'),
          ec2.InitPackage.apt('gcc'),
          ec2.InitPackage.apt('gcc-13-locales'),
          ec2.InitPackage.apt('gettext'),
          ec2.InitPackage.apt('git'),
          ec2.InitPackage.apt('gnu-standards'),
          ec2.InitPackage.apt('graphviz'),
          ec2.InitPackage.apt('libgd-dev'),
          ec2.InitPackage.apt('libgsl-dev'),
          ec2.InitPackage.apt('libgraphviz-dev'),
          ec2.InitPackage.apt('libcurl4-openssl-dev'),
          ec2.InitPackage.apt('libssl-dev'),
          ec2.InitPackage.apt('libtool'),
          ec2.InitPackage.apt('libxml2-dev'),
          ec2.InitPackage.apt('libzip-dev'),
          ec2.InitPackage.apt('make'),
          ec2.InitPackage.apt('nginx'),
          ec2.InitPackage.apt('openssh-server'),
          ec2.InitPackage.apt('pipx'),
          ec2.InitPackage.apt('pkg-config'),
          ec2.InitPackage.apt('plocate'),
          ec2.InitPackage.apt('python3'),
          ec2.InitPackage.apt('python3-certbot-nginx'),
          ec2.InitPackage.apt('python3-pip'),
          ec2.InitPackage.apt('rsync'),
          ec2.InitPackage.apt('sqlite3'),
          ec2.InitPackage.apt('sysstat'),
          ec2.InitPackage.apt('unattended-upgrades'),
          ec2.InitPackage.apt('unzip'),
          ec2.InitPackage.apt('update-notifier-common'),
          ec2.InitPackage.apt('uuid-dev'),
          ec2.InitCommand.shellCommand('systemctl is-active sysstat'),
          ec2.InitCommand.shellCommand('systemctl enable unattended-upgrades'),
        ]),
        createUsers: new ec2.InitConfig([
          ec2.InitFile.fromString(
            '/tmp/hostnamedata',
            `hostname: ${hostname}\ndomainName: ${props.domainName}`,
            {
              mode: '000444',
              owner: 'root',
              group: 'root'
            }
          ),
          ec2.InitFile.fromString(
            `/etc/sudoers.d/90-nopasswd-adm`,
            `%adm ALL=(ALL) NOPASSWD:ALL`,
            {
              mode: '000440', // Sudoers files MUST be read-only (440) for security
              owner: 'root',
              group: 'root',
            },
          ),
          ec2.InitFile.fromString(
            `/etc/sudoers.d/91-appuser-${props.prefix}`,
            'appuser ALL=' + [
              `NOPASSWD:/usr/bin/systemctl start ${props.prefix}`,
              `NOPASSWD:/usr/bin/systemctl stop ${props.prefix}`,
              `NOPASSWD:/usr/bin/systemctl restart ${props.prefix}`,
              'NOPASSWD:/usr/bin/systemctl reload nginx',
              'NOPASSWD:/usr/bin/systemctl restart nginx',
              'NOPASSWD:/opt/prefix/bin/setup-nginx.sh'
            ].join(', '),  
            {
              mode: '000440',
              owner: 'root',
              group: 'root',
            },
         ),
          ec2.InitUser.fromName('appuser', {
            homeDir: '/opt/prefix',
            groups: ['www-data'],
          }),
          ec2.InitCommand.shellCommand(
            '/usr/bin/chsh -s /sbin/nologin appuser',
          ),
          ec2.InitUser.fromName('luke', {
            groups: [
              'users',
              'admin',
              'adm',
              'man',
              'sudo',
              'operator',
              'src',
              'staff',
              'crontab',
              'www-data',
            ],
          }),
          ec2.InitCommand.shellCommand('cp -a /etc/skel /home/luke'),
          ec2.InitCommand.shellCommand('chown -R luke:luke /home/luke'),
          ec2.InitCommand.shellCommand('/usr/bin/chsh -s /bin/bash luke'),
          // TODO: set up sudo for 'luke' user.
          ec2.InitCommand.shellCommand(
            ' /usr/sbin/groupmod -a appuser -U luke',
          ),
          ec2.InitCommand.shellCommand('mkdir -p /home/luke/.ssh'),
          ec2.InitCommand.shellCommand('chmod 700 /home/luke/.ssh'),
          ec2.InitCommand.shellCommand(
            `cp ${local_ssh_keys_path} /home/luke/.ssh/authorized_keys`,
          ),
          ec2.InitCommand.shellCommand(
            'chmod 600 /home/luke/.ssh/authorized_keys',
          ),
          ec2.InitCommand.shellCommand('chown -R luke:luke /home/luke/.ssh'),
        ]),
        configureSSM: new ec2.InitConfig([
          ec2.InitCommand.shellCommand('apt-get remove --purge -y snapd'),
          ec2.InitCommand.shellCommand(
            'curl "https://s3.amazonaws.com/ec2-downloads-windows/SSMAgent/latest/debian_arm64/amazon-ssm-agent.deb" -o "/tmp/amazon-ssm-agent.deb"',
          ),
          ec2.InitCommand.shellCommand('dpkg -i /tmp/amazon-ssm-agent.deb'),
          ec2.InitCommand.shellCommand('systemctl enable amazon-ssm-agent'),
          ec2.InitCommand.shellCommand('systemctl start amazon-ssm-agent'),
        ]),
        configureApp: new ec2.InitConfig([
          ec2.InitFile.fromObject('/etc/stack.json', {
            stackId: Stack.of(stack).stackId,
            stackName: Stack.of(stack).stackName,
            region: Stack.of(stack).region,
          }),
          ec2.InitService.enable('atd', {
            ensureRunning: true,
            serviceManager: ec2.ServiceManager.SYSTEMD,
          }),
          ec2.InitCommand.shellCommand(`hostname ${hostname}`),
          ec2.InitCommand.shellCommand(`hostnamectl set-hostname ${hostname}`),
          ec2.InitCommand.shellCommand(
            `echo "127.0.1.1 ${hostname} ${hostname}.localdoamin" >> /etc/hosts`,
          ),
          ec2.InitCommand.shellCommand('mkdir -p /opt/prefix/var/run'),
          ec2.InitCommand.shellCommand('mkdir -p /opt/prefix/var/log'),
          ec2.InitCommand.shellCommand('mkdir -p /opt/prefix/.config/mise'),
          ec2.InitCommand.shellCommand('mkdir -p /opt/prefix/bin'),
          ec2.InitCommand.shellCommand('mkdir -p /opt/prefix/etc'),
          ec2.InitCommand.shellCommand('chown -R appuser:www-data /opt/prefix'),
          ec2.InitCommand.shellCommand(
            'sudo -u appuser touch /opt/prefix/.bash_profile',
          ),
          ec2.InitCommand.shellCommand(
            `echo 'export PATH="/opt/prefix/.local/bin/:$HOME/bin:$PATH"' >> /opt/prefix/.bash_profile`,
          ),
          ec2.InitCommand.shellCommand('mkdir /etc/nginx/ssl'),
          ec2.InitCommand.shellCommand(
            `openssl req -x509 -newkey rsa:2048 -keyout /etc/nginx/ssl/${props.domainName}.key -out /etc/nginx/ssl/${props.domainName}.crt -days 365 -nodes -subj "/C=US/ST=State/L=City/O=Org/OU=OrgUnit/CN=localhost"`,
          ),
          // if there is not a cert present where the nginx config states, then
          // when certbot runs, it checks the nginx config syntax for correctness and it will fail
          ec2.InitCommand.shellCommand(
            'chown -R www-data:www-data /etc/nginx/ssl',
          ),
          ec2.InitCommand.shellCommand(
            'sync && echo 3 > /proc/sys/vm/drop_caches',
          ),
          ec2.InitCommand.shellCommand(
            `mkdir -p /opt/prefix/var/log/Perl/dist/${props.mainPerlDistro}/`,
          ),
          ec2.InitCommand.shellCommand(
            `mkdir -p /home/luke/var/log/Perl/dist/${props.mainPerlDistro}/`,
          ),
          ec2.InitCommand.shellCommand(
            'chown -R appuser:www-data /opt/prefix/var',
          ),
          ec2.InitCommand.shellCommand('chown -R luke:luke /home/luke/var'),
          ec2.InitCommand.shellCommand(
            'find /opt/prefix/var -type d -exec chmod g+rx {} \\;',
          ),
          ec2.InitCommand.shellCommand(
            `cd /opt/prefix/bin && unzip ${local_bin_path}`,
          ),
          ec2.InitCommand.shellCommand('chown -R appuser:www-data /opt/prefix'),
          ec2.InitCommand.shellCommand('chmod +x /opt/prefix/bin/*.sh'),
          ec2.InitCommand.shellCommand('chmod +x /opt/prefix/bin/appperl'),
          ec2.InitCommand.shellCommand(
            'mv /opt/prefix/bin/.bash* /opt/prefix/',
          ),
          ec2.InitCommand.shellCommand(
            `sed -i -E 's/PREFIXREPLACE/${props.prefix}/g' /opt/prefix/bin/deploy-prefix.sh`
          ),
          ec2.InitCommand.shellCommand(
            'cp /opt/prefix/bin/deploy-prefix.sh /usr/local/bin',
          ),
          ec2.InitCommand.shellCommand(
            'chmod 0755 /opt/prefix/bin/deploy-prefix.sh',
          ),

          ec2.InitCommand.shellCommand(
            `sed -i -E 's|REPLACE_BUCKET|${props.appCodeAsset.s3BucketName}|;' /opt/prefix/bin/bootstrap.sh`,
          ),
          ec2.InitCommand.shellCommand(
            `sed -i -E 's|REPLACE_KEY|${props.appCodeAsset.s3ObjectKey}|;'  /opt/prefix/bin/bootstrap.sh`,
          ),
          ec2.InitCommand.shellCommand(
            `sed -i -E 's|MODEREPLACE|${props.mode === 'prod' ? 'www' : props.mode}|' /opt/prefix/bin/bootstrap.sh`,
          ),
          ec2.InitCommand.shellCommand(
            `sed -i -E 's|PREFIXREPLACE|${props.prefix}|g' /opt/prefix/bin/bootstrap.sh`
          ),
          ec2.InitCommand.shellCommand(
            `sed -i -E 's|PROPSDOMAIN|${props.domainName}|g' /opt/prefix/bin/bootstrap.sh`
          ),
          ec2.InitCommand.shellCommand(
            'chmod 0755 /usr/local/bin/*.sh',
          ),
          ec2.InitCommand.shellCommand('mkdir -p /tmp/prefix_etc'),
          ec2.InitCommand.shellCommand(
            `cd /tmp/prefix_etc && unzip ${local_etc_path}`,
          ),
          ec2.InitCommand.shellCommand(
            'sudo cp /tmp/prefix_etc/trusted.toml /opt/prefix/.config/mise',
          ),
          ec2.InitCommand.shellCommand(
            'sudo chown appuser:appuser /opt/prefix/.config/mise/trusted.toml',
          ),

          // Run bootstrap in background - it will start ${props.prefix}.service when done
          ec2.InitCommand.shellCommand(
            'echo "bash /opt/prefix/bin/bootstrap.sh > /opt/prefix/var/log/bootstrap.log 2>&1" | sudo -u appuser  at now',
          ),
          ec2.InitCommand.shellCommand(
            `sudo cp /tmp/prefix_etc/sysctl.conf /etc/sysctl.d/${props.prefix}.conf`,
          ),
          ec2.InitCommand.shellCommand('sudo service procps force-reload'),

          ec2.InitCommand.shellCommand(
            `sed -i -E 's/PREFIXREPLACE/${props.prefix}/g' /tmp/prefix_etc/template.service`
          ),
          ec2.InitCommand.shellCommand(
            `sudo cp /tmp/prefix_etc/template.service /etc/systemd/system/${props.prefix}.service`,
          ),
          ec2.InitCommand.shellCommand(
            `sudo sed -i -E 's|REPLACEMODE|${this.mode_to_stage(props.mode)}|' /etc/systemd/system/${props.prefix}.service`
          ),
          ec2.InitCommand.shellCommand(
            `cp /tmp/prefix_etc/logrotate-template.conf /etc/logrotate.d/${props.prefix}`,
          ),
          ec2.InitCommand.shellCommand(`chmod 644 /etc/logrotate.d/${props.prefix}`),

          ec2.InitCommand.shellCommand('sudo systemctl daemon-reload'),

          // Schedule cert setup to run 2 minutes after boot (DNS needs time to propagate)
          // Script has its own retry logic, no systemd service needed

          ec2.InitCommand.shellCommand(
            `echo "/opt/prefix/bin/rootBootstrap.sh --mode ${props.mode} --domain1 ${props.domainName}; >> /var/log/bootstrap.log" | at now + 2 minutes`,
          ),
          // The PDL perl package compile takes *forever*, so give this a generous amount of time.
          ec2.InitCommand.shellCommand(
            `echo "/usr/bin/systemctl enable ${props.prefix}" | at now + 30 minutes`,
          ),
          ec2.InitCommand.shellCommand(
            `echo "/usr/bin/systemctl start ${props.prefix}" | at now + 60 minutes`,
          ),
        ]),
      },
    });

    this.initOptions = {
      configSets: ['default'],
      timeout: cdk.Duration.minutes(35),
      ignoreFailures: false, // Don't rollback on failure during debugging
    };
    // Note: CDK automatically appends cfn-init call when Instance has init + userData
  }
}
