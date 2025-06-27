#!/bin/bash
set -ex

container_workdir="/app"
github_action_path=$(dirname "$0")
docker_tag=$(cat ./docker_tag)
echo "Docker tag: $docker_tag" >> output.log 2>&1

phar_url="https://getcomposer.org/"
# check if $ACTION_VERSION is not set or empty or set to latest
if [ -z "$ACTION_VERSION" ] || [ "$ACTION_VERSION" == "latest" ];
then
	# if a version is not set, use latest composer version
	phar_url="${phar_url}download/latest-stable/composer.phar"
else
	# if a version is set, choose the correct download
	case "$ACTION_VERSION" in
		# get the latest preview
		Preview | preview)
		phar_url="${phar_url}download/latest-preview/composer.phar"
		;;
		# get the latest snapshot
		Snapshot | snapshot)
		phar_url="${phar_url}composer.phar"
		;;
		# get the latest version of the v1 tree
		1 | 1.x)
		phar_url="${phar_url}download/latest-1.x/composer.phar"
		;;
		# get the latest version of the v2 tree
		2 | 2.x)
		phar_url="${phar_url}download/latest-2.x/composer.phar"
		;;
		# get the latest version of the v2.2 tree
		2.2 | 2.2.x)
		phar_url="${phar_url}download/latest-2.2.x/composer.phar"
		;;
		# if the version is not one of the above, assume that it is a exact
		# naming, possibly with additions (RC, beta1, ...)
		*)
		phar_url="${phar_url}download/${ACTION_VERSION}/composer.phar"
		;;
	esac
fi
curl --silent -H "User-agent: cURL (https://github.com/php-actions)" -L "$phar_url" > "${github_action_path}/composer.phar"
chmod +x "${github_action_path}/composer.phar"

# command_string is passed directly to the docker executable. It includes the
# container name and version, and this script will build up the rest of the
# arguments according to the action's input values.
command_string="composer"

# In case there is need to install private repositories, SSH details are stored
# in these two places, which are mounted on the Composer docker container later.
ssh_path="${github_action_path}/__tmp/ssh"
gitconfig_path="${github_action_path}/__tmp/gitconfig"
mkdir -p "$ssh_path"
touch "$gitconfig_path"

if [ -n "$ACTION_SSH_KEY" ]
then
	echo "Storing private key file for root" >> output.log 2>&1
	ssh-keyscan -t rsa github.com >> "$ssh_path/known_hosts"
	ssh-keyscan -t rsa gitlab.com >> "$ssh_path/known_hosts"
	ssh-keyscan -t rsa bitbucket.org >> "$ssh_path/known_hosts"

	if [ -n "$ACTION_SSH_DOMAIN" ]
	then
		if [ -n "$ACTION_SSH_PORT" ]
		then
			ssh-keyscan -t rsa -p $ACTION_SSH_PORT "$ACTION_SSH_DOMAIN" >> "$ssh_path/known_hosts"
                else
			ssh-keyscan -t rsa "$ACTION_SSH_DOMAIN" >> "$ssh_path/known_hosts"
		fi
	fi

	echo "$ACTION_SSH_KEY" > "$ssh_path/action_rsa"
	echo "$ACTION_SSH_KEY_PUB" > "$ssh_path/action_rsa.pub"
	chmod 600 "$ssh_path/action_rsa"

	echo "PRIVATE KEY:" >> output.log 2>&1
	md5sum "$ssh_path/action_rsa" >> output.log 2>&1
	echo "PUBLIC KEY:" >> output.log 2>&1
	md5sum "$ssh_path/action_rsa.pub" >> output.log 2>&1

	echo "[core]" >> "$gitconfig_path"
	echo "sshCommand = \"ssh -i ~/.ssh/action_rsa\"" >> "$gitconfig_path"
else
	echo "No private keys supplied" >> output.log 2>&1
fi

if [ -n "$ACTION_COMMAND" ]
then
	command_string="$command_string $ACTION_COMMAND"
fi

if [ -n "$ACTION_WORKING_DIR" ]
then
	command_string="$command_string --working-dir=$ACTION_WORKING_DIR"
fi

# If the ACTION_ONLY_ARGS has _not_ been passed, then we build up the arguments
# that have been specified. The else condition to this if statement allows
# the developer to specify exactly what arguments to pass to Composer.
if [ -z "$ACTION_ONLY_ARGS" ]
then
	if [ "$ACTION_COMMAND" = "install" ]
	then
        	case "$ACTION_DEV" in
        		yes)
        			# Default behaviour
        		;;
        		no)
        			command_string="$command_string --no-dev"
        		;;
        		*)
        			echo "Invalid input for action argument: dev (must be yes or no)"
        			exit 1
        		;;
        	esac

        	case "$ACTION_PROGRESS" in
        		yes)
        			# Default behaviour
        		;;
        		no)
        			command_string="$command_string --no-progress"
        		;;
        		*)
        			echo "Invalid input for action argument: progress (must be yes or no)"
        			exit 1
        		;;
        	esac
	fi

	case "$ACTION_INTERACTION" in
		yes)
			# Default behaviour
		;;
		no)
			command_string="$command_string --no-interaction"
		;;
		*)
			echo "Invalid input for action argument: interaction  (must be yes or no)"
			exit 1
		;;
	esac

	case "$ACTION_QUIET" in
		yes)
			command_string="$command_string --quiet"
		;;
		no)
			# Default behaviour
		;;
		*)
			echo "Invalid input for action argument: quiet (must be yes or no)"
			exit 1
		;;
	esac

	if [ -n "$ACTION_ARGS" ]
	then
		command_string="$command_string $ACTION_ARGS"
	fi
else
	command_string="$command_string $ACTION_ONLY_ARGS"
fi

if [ -n "$ACTION_MEMORY_LIMIT" ]
then
  memory_limit="--env COMPOSER_MEMORY_LIMIT=$ACTION_MEMORY_LIMIT"
else
  memory_limit=''
fi

echo "Command: $command_string" >> output.log 2>&1
mkdir -p /tmp/composer-cache

export COMPOSER_CACHE_DIR="/tmp/composer-cache"
unset ACTION_SSH_KEY
unset ACTION_SSH_KEY_PUB

dockerKeys=()
while IFS= read -r line
do
	dockerKeys+=( $(echo "$line" | cut -f1 -d=) )
done <<<$(docker run --rm "${docker_tag}" env)

while IFS= read -r line
do
	key=$(echo "$line" | cut -f1 -d=)
	if printf '%s\n' "${dockerKeys[@]}" | grep -q -P "^${key}\$"
	then
    		echo "Skipping env variable $key" >> output.log
	else
		echo "$line" >> DOCKER_ENV
	fi
done <<<$(env)

if [ -n "$ACTION_CONTAINER_WORKDIR" ]; then
	container_workdir="${ACTION_CONTAINER_WORKDIR}"
fi

echo "name=full_command::${command_string}" >> $GITHUB_OUTPUT

docker run --rm \
	--volume "${github_action_path}/composer.phar":/usr/local/bin/composer \
	--volume "$gitconfig_path":/root/.gitconfig \
	--volume "$ssh_path":/root/.ssh \
	--volume "${GITHUB_WORKSPACE}":/app \
	--volume "/tmp/composer-cache":/tmp/composer-cache \
	--workdir ${container_workdir} \
	--env-file ./DOCKER_ENV \
	--network host \
	${memory_limit} \
	${docker_tag} ${command_string}
	
rm -rf "${github_action_path}/__tmp"

