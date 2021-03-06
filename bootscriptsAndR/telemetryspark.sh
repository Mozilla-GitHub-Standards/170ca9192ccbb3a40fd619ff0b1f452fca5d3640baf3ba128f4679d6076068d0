## This is not needed if the kickstart.sh has already been run, since that script inserts
## this anways
# Y1=`Rscript -e 'cat(strsplit(readLines("/home/hadoop/.aws/config")[2],"=[ ]+")[[1]][[2]])'`
# Y2=`Rscript -e 'cat(strsplit(readLines("/home/hadoop/.aws/config")[3],"=[ ]+")[[1]][[2]])'`
# (
    
# cat <<EOF

# export AWS_ACCESS_KEY_ID=${Y1}
# export AWS_SCERET_ACCESS_KEY=${Y2}

# EOF
# ) >> $HOME/.bashrc

source ~/.bashrc

sudo yum -y install git jq htop tmux libffi-devel

INSTANCES=$(jq .instanceCount /mnt/var/lib/info/job-flow.json)
FLOWID=$(jq -r .jobFlowId /mnt/var/lib/info/job-flow.json)
EXECUTORS=$(($INSTANCES>1?$INSTANCES:2 - 1))
EXECUTOR_CORES=$(nproc)
MAX_YARN_MEMORY=$(grep /home/hadoop/conf/yarn-site.xml -e "yarn\.scheduler\.maximum-allocation-mb" | sed 's/.*<value>\(.*\).*<\/value>.*/\1/g')
EXECUTOR_MEMORY=$(echo "($MAX_YARN_MEMORY - 1024 - 384) - ($MAX_YARN_MEMORY - 1024 - 384) * 0.07 " | bc | cut -d'.' -f1)M
DRIVER_MEMORY=$EXECUTOR_MEMORY
HOME=/home/hadoop

# Error message
error_msg ()
{
	echo 1>&2 "Error: $1"
}

# Check for master node
IS_MASTER=true
if [ -f /mnt/var/lib/info/instance.json ]
then
	IS_MASTER=$(jq .isMaster /mnt/var/lib/info/instance.json)
fi

# Parse arguments
while [ $# -gt 0 ]; do
	case "$1" in
		--num-executors)
			shift
			EXECUTORS=$1
			;;
		--executor-cores)
			shift
			EXECUTOR_CORES=$1
			;;
		--executor-memory)
			shift
			EXECUTOR_MEMORY=$1g
			;;
		--driver-memory)
			shift
			DRIVER_MEMORY=$1g
			;;
		--public-key)
			shift
			PUBLIC_KEY=$1
			;;
		--timeout)
			shift
			TIMEOUT=$1
			;;
		-*)
			# do not exit out, just note failure
			error_msg "unrecognized option: $1"
			;;
		*)
			break;
			;;
	esac
	shift
done

# Setup Spark
sudo chown hadoop:hadoop /mnt

# Force Python 2.7
sudo rm /usr/bin/python /usr/bin/pip
sudo ln -s /usr/bin/python2.7 /usr/bin/python
sudo ln -s /usr/bin/pip-2.7 /usr/bin/pip
sudo sed -i '1c\#!/usr/bin/python2.6' /usr/bin/yum

# Setup Python
sudo pip install py4j python_moztelemetry requests[security] boto pyliblzma numpy pandas ipython==2.4.1 \
  pyzmq jinja2 tornado ujson statsmodels runipy plotly montecarlino

# Fix empty backports.ssl-match-hostname package
sudo /usr/bin/yes | sudo pip uninstall backports.ssl_match_hostname && sudo pip install backports.ssl_match_hostname

# Add public key
if [ -n "$PUBLIC_KEY" ]; then
	echo $PUBLIC_KEY >> $HOME/.ssh/authorized_keys
fi

# Schedule shutdown at timeout
if [ ! -z $TIMEOUT ]; then
	sudo shutdown -h +$TIMEOUT&
fi

# Continue only if master node
if [ "$IS_MASTER" = false ]; then
	exit
fi

# Configure environment variables
cat << EOF >> $HOME/.bashrc
# Spark configuration
export PYTHONPATH=$HOME/spark/python/
export SPARK_HOME=$HOME/spark
export _JAVA_OPTIONS="-Dlog4j.configuration=file:///home/hadoop/spark/conf/log4j.properties -Xmx$DRIVER_MEMORY"
EOF

# Here we are using striping on the assumption that we have a layout with 2 SSD disks!
SPARK_CONF=$(cat <<EOF
--conf spark.local.dir=/mnt \
--conf spark.akka.frameSize=500 \
--conf spark.io.compression.codec=lzf \
--conf spark.serializer=org.apache.spark.serializer.KryoSerializer
EOF
)

if [ $EXECUTORS -eq 1 ]; then
	echo "export PYSPARK_SUBMIT_ARGS=\"--master local[*] $SPARK_CONF\"" >> $HOME/.bashrc
else
	echo "export PYSPARK_SUBMIT_ARGS=\"--master yarn --deploy-mode client --num-executors $EXECUTORS --executor-memory $EXECUTOR_MEMORY --executor-cores $EXECUTOR_CORES $SPARK_CONF\"" >> $HOME/.bashrc
fi

source $HOME/.bashrc

# Setup IPython
ipython profile create
cat << EOF > $HOME/.ipython/profile_default/startup/00-pyspark-setup.py
import os

spark_home = os.environ.get('SPARK_HOME', None)
execfile(os.path.join(spark_home, 'python/pyspark/shell.py'))
EOF

# Dump Spark logs to a file
cat << EOF > $SPARK_HOME/conf/log4j.properties
# Initialize root logger
log4j.rootLogger=INFO, FILE

# Set everything to be logged to the console
log4j.rootCategory=INFO, FILE

# Ignore messages below warning level from Jetty, because it's a bit verbose
log4j.logger.org.eclipse.jetty=WARN

# Set the appender named FILE to be a File appender
log4j.appender.FILE=org.apache.log4j.FileAppender

# Change the path to where you want the log file to reside
log4j.appender.FILE.File=$HOME/spark.log

# Prettify output a bit
log4j.appender.FILE.layout=org.apache.log4j.PatternLayout
log4j.appender.FILE.layout.ConversionPattern=%d{yy/MM/dd HH:mm:ss} %p %c{1}: %m%n
EOF

# Setup plotly
mkdir $HOME/.plotly && aws s3 cp s3://telemetry-spark-emr/plotly_credentials $HOME/.plotly/.credentials


## Append this to the end of the
## ~/.ipython/profile_default/ipython_notebook_config.py
cat << EOF > $HOME/.ipython/profile_default/ipython_notebook_config.py
c = get_config()
c.IPKernelApp.pylab = 'inline' 
c.NotebookApp.ip = '*'
c.NotebookApp.open_browser = False
c.NotebookApp.port = 1978
EOF

mkdir -p $HOME/analyses && cd $HOME/analyses
wget https://gist.githubusercontent.com/vitillo/e1813025e7d26d640c80/raw/79245cdabe4207a6a29548f8c3192ed180a6f9f5/Telemetry%20Hello%20World.ipynb
ipython notebook &

