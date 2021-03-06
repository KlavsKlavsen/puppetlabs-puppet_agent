#!/bin/sh
# Install puppet-agent as a task
#
# From https://github.com/petems/puppet-install-shell/blob/master/install_puppet_5_agent.sh

# Timestamp
now () {
    date +'%H:%M:%S %z'
}

# Logging functions instead of echo
log () {
    echo "`now` ${1}"
}

info () {
    log "INFO: ${1}"
}

warn () {
    log "WARN: ${1}"
}

critical () {
    log "CRIT: ${1}"
}

utopic () {
    warn "There is no utopic release yet, see https://tickets.puppetlabs.com/browse/CPR-92 for progress";
    warn "We'll use the trusty package for now";
    deb_codename="trusty";
}

# Check whether a command exists - returns 0 if it does, 1 if it does not
exists() {
  if command -v $1 >/dev/null 2>&1
  then
    return 0
  else
    return 1
  fi
}

# Get command line arguments

if [ -n "$PT_version" ]; then
  version=$PT_version
fi

if [ -n "$PT_collection" ]; then
  collection=$PT_collection
else
  collection='puppet'
fi

shift `expr $OPTIND - 1`

machine=`uname -m`
os=`uname -s`

if [ `id -u` -ne 0 ]; then
  echo "puppet_agent::install task must be run as root"
  exit 1
fi

if [ -f /opt/puppetlabs/puppet/VERSION ]; then
  installed_version=`cat /opt/puppetlabs/puppet/VERSION`
else
  installed_version=uninstalled
fi

# Retrieve Platform and Platform Version
if test -f "/etc/lsb-release" && grep -q DISTRIB_ID /etc/lsb-release; then
  platform=`grep DISTRIB_ID /etc/lsb-release | cut -d "=" -f 2 | tr '[A-Z]' '[a-z]'`
  platform_version=`grep DISTRIB_RELEASE /etc/lsb-release | cut -d "=" -f 2`
elif test -f "/etc/debian_version"; then
  platform="debian"
  platform_version=`cat /etc/debian_version`
elif test -f "/etc/redhat-release"; then
  platform=`sed 's/^\(.\+\) release.*/\1/' /etc/redhat-release | tr '[A-Z]' '[a-z]'`
  platform_version=`sed 's/^.\+ release \([.0-9]\+\).*/\1/' /etc/redhat-release`

  #If /etc/redhat-release exists, we act like RHEL by default. Except for fedora
  if test "$platform" = "fedora"; then
    platform="fedora"
  else
    platform="el"
  fi
elif test -f "/etc/system-release"; then
  platform=`sed 's/^\(.\+\) release.\+/\1/' /etc/system-release | tr '[A-Z]' '[a-z]'`
  platform_version=`sed 's/^.\+ release \([.0-9]\+\).*/\1/' /etc/system-release | tr '[A-Z]' '[a-z]'`
  # amazon is built off of fedora, so act like RHEL
  if test "$platform" = "amazon linux ami"; then
    platform="el"
    platform_version="6.0"
  fi
# Apple OS X
elif test -f "/usr/bin/sw_vers"; then
  platform="mac_os_x"
  # Matching the tab-space with sed is error-prone
  platform_version=`sw_vers | awk '/^ProductVersion:/ { print $2 }'`

  major_version=`echo $platform_version | cut -d. -f1,2`
  case $major_version in
    "10.11") platform_version="10.11";;
    "10.12") platform_version="10.12";;
    "10.13") platform_version="10.13";;
    *) echo "No builds for platform: $major_version"
       exit 1
       ;;
  esac

  # x86_64 Apple hardware often runs 32-bit kernels (see OHAI-63)
  x86_64=`sysctl -n hw.optional.x86_64`
  if test $x86_64 -eq 1; then
    machine="x86_64"
  fi
elif test -f "/etc/release"; then
  platform="solaris2"
  machine=`/usr/bin/uname -p`
  platform_version=`/usr/bin/uname -r`
elif test -f "/etc/SuSE-release"; then
  if grep -q 'Enterprise' /etc/SuSE-release;
  then
      platform="sles"
      platform_version=`awk '/^VERSION/ {V = $3}; /^PATCHLEVEL/ {P = $3}; END {print V "." P}' /etc/SuSE-release`
  else
      platform="suse"
      platform_version=`awk '/^VERSION =/ { print $3 }' /etc/SuSE-release`
  fi
elif test -f "/etc/arch-release"; then
  platform="archlinux"
  platform_version=`/usr/bin/uname -r`
elif test "x$os" = "xFreeBSD"; then
  platform="freebsd"
  platform_version=`uname -r | sed 's/-.*//'`
elif test "x$os" = "xAIX"; then
  platform="aix"
  platform_version=`uname -v`
  machine="ppc"
fi

if test "x$platform" = "x"; then
  critical "Unable to determine platform version!"
  exit 1
fi

if test "x$version" = "x"; then
  version="latest";
  info "Version parameter not defined, assuming latest";
else
  info "Version parameter defined: $version";
  puppet_agent_version=$version
fi

# Mangle $platform_version to pull the correct build
# for various platforms
major_version=`echo $platform_version | cut -d. -f1`
case $platform in
  "el")
    platform_version=$major_version
    ;;
  "fedora")
    case $major_version in
      "23") platform_version="22";;
      *) platform_version=$major_version;;
    esac
    ;;
  "debian")
    case $major_version in
      "5") platform_version="6";;
      "6") platform_version="6";;
      "7") platform_version="6";;
    esac
    ;;
  "freebsd")
    platform_version=$major_version
    ;;
  "sles")
    platform_version=$major_version
    ;;
  "suse")
    platform_version=$major_version
    ;;
esac

# Find which version of puppet is currently installed if any

if test "x$platform_version" = "x"; then
  critical "Unable to determine platform version!"
  exit 1
fi

if test "x$platform" = "xsolaris2"; then
  # hack up the path on Solaris to find wget
  PATH=/usr/sfw/bin:$PATH
  export PATH
fi

unable_to_retrieve_package() {
  critical "Unable to retrieve a valid package!"
  exit 1
}

random_hexdump () {
  hexdump -n 2 -e '/2 "%u"' /dev/urandom
}

if test "x$TMPDIR" = "x"; then
  tmp="/tmp"
else
  tmp=${TMPDIR}
  # TMPDIR has trailing file sep for OSX test box
  penultimate=$((${#tmp}-1))
  if test "${tmp:$penultimate:1}" = "/"; then
    tmp="${tmp:0:$penultimate}"
  fi
fi

# Random function since not all shells have $RANDOM
if exists hexdump; then
  random_number=$(random_hexdump)
else
  random_number="`date +%N`"
fi

tmp_dir="$tmp/install.sh.$$.$random_number"
(umask 077 && mkdir $tmp_dir) || exit 1

tmp_stderr="$tmp/stderr.$$.$random_number"

capture_tmp_stderr() {
  # spool up tmp_stderr from all the commands we called
  if test -f $tmp_stderr; then
    output=`cat ${tmp_stderr}`
    stderr_results="${stderr_results}\nSTDERR from $1:\n\n$output\n"
  fi
}

trap "rm -f $tmp_stderr; rm -rf $tmp_dir; exit $1" 1 2 15

# do_wget URL FILENAME
do_wget() {
  info "Trying wget..."
  wget -O "$2" "$1" 2>$tmp_stderr
  rc=$?

  # check for 404
  grep "ERROR 404" $tmp_stderr 2>&1 >/dev/null
  if test $? -eq 0; then
    critical "ERROR 404"
    unable_to_retrieve_package
  fi

  # check for bad return status or empty output
  if test $rc -ne 0 || test ! -s "$2"; then
    capture_tmp_stderr "wget"
    return 1
  fi

  return 0
}

# do_curl URL FILENAME
do_curl() {
  info "Trying curl..."
  curl -1 -sL -D $tmp_stderr "$1" > "$2"
  rc=$?
  # check for 404
  grep "404 Not Found" $tmp_stderr 2>&1 >/dev/null
  if test $? -eq 0; then
    critical "ERROR 404"
    unable_to_retrieve_package
  fi

  # check for bad return status or empty output
  if test $rc -ne 0 || test ! -s "$2"; then
    capture_tmp_stderr "curl"
    return 1
  fi

  return 0
}

# do_fetch URL FILENAME
do_fetch() {
  info "Trying fetch..."
  fetch -o "$2" "$1" 2>$tmp_stderr
  # check for bad return status
  test $? -ne 0 && return 1
  return 0
}

# do_perl URL FILENAME
do_perl() {
  info "Trying perl..."
  perl -e 'use LWP::Simple; getprint($ARGV[0]);' "$1" > "$2" 2>$tmp_stderr
  rc=$?
  # check for 404
  grep "404 Not Found" $tmp_stderr 2>&1 >/dev/null
  if test $? -eq 0; then
    critical "ERROR 404"
    unable_to_retrieve_package
  fi

  # check for bad return status or empty output
  if test $rc -ne 0 || test ! -s "$2"; then
    capture_tmp_stderr "perl"
    return 1
  fi

  return 0
}

# do_download URL FILENAME
do_download() {
  info "Downloading $1"
  info "  to file $2"

  # we try all of these until we get success.
  # perl, in particular may be present but LWP::Simple may not be installed

  if exists wget; then
    do_wget $1 $2 && return 0
  fi

  if exists curl; then
    do_curl $1 $2 && return 0
  fi

  if exists fetch; then
    do_fetch $1 $2 && return 0
  fi

  if exists perl; then
    do_perl $1 $2 && return 0
  fi

  unable_to_retrieve_package
}

# install_file TYPE FILENAME
# TYPE is "rpm", "deb", "solaris" or "dmg"
install_file() {
  case "$1" in
    "rpm")
      info "installing puppetlabs yum repo with rpm..."
      if test -f "/etc/yum.repos.d/puppetlabs-pc1.repo"; then
        info "existing puppetlabs yum repo found, moving to old location"
        mv /etc/yum.repos.d/puppetlabs-pc1.repo /etc/yum.repos.d/puppetlabs-pc1.repo.old
      fi

      if test "x$installed_version" != "xuninstalled"; then
        info "Version ${installed_version} detected..."
        major=$(echo $installed_version | cut -d. -f1)
        pkg="puppet${major}-release"

        if echo $2 | grep $pkg; then
          info "No collection upgrade detected"
        else
          info "Collection upgrade detected, replacing puppet${major}-release"
          rpm -e "puppet${major}-release"
        fi
      fi

      rpm -Uvh --oldpackage --replacepkgs "$2"
      if test "$version" = 'latest'; then
        yum install -y puppet-agent && yum upgrade -y puppet-agent
      else
        yum install -y "puppet-agent-${puppet_agent_version}"
      fi
      ;;
    "noarch.rpm")
      info "installing puppetlabs yum repo with zypper..."

      if test "x$installed_version" != "xuninstalled"; then
        info "Version ${installed_version} detected..."
        major=$(echo $installed_version | cut -d. -f1)
        pkg="puppet${major}-release"

        if echo $2 | grep $pkg; then
          info "No collection upgrade detected"
        else
          info "Collection upgrade detected, replacing puppet${major}-release"
          zypper remove --no-confirm "puppet${major}-release"
        fi
      fi

      zypper install --no-confirm "$2"
      if test "$version" = "latest"; then
        zypper install --no-confirm "puppet-agent"
      else
        zypper install --no-confirm --oldpackage --no-recommends --no-confirm "puppet-agent-${puppet_agent_version}"
      fi
      ;;
    "deb")
      info "installing puppetlabs apt repo with dpkg..."

      if test "x$installed_version" != "xuninstalled"; then
        info "Version ${installed_version} detected..."
        major=$(echo $installed_version | cut -d. -f1)
        pkg="puppet${major}-release"

        if echo $2 | grep $pkg; then
          info "No collection upgrade detected"
        else
          info "Collection upgrade detected, replacing puppet${major}-release"
          dpkg --purge "puppet${major}-release"
        fi
      fi

      dpkg -i "$2"
      apt-get update -y

      if test "$version" = 'latest'; then
        apt-get install -y puppet-agent
      else
        if test "x$deb_codename" != "x"; then
          apt-get install -y "puppet-agent=${puppet_agent_version}-1${deb_codename}"
        else
          apt-get install -y "puppet-agent=${puppet_agent_version}"
        fi
      fi
      ;;
    "solaris")
      critical "Solaris not supported yet"
      ;;
    "dmg" )
      info "installing puppetlabs dmg with hdiutil and installer"
      mountpoint="$(mktemp -d -t $(random_hexdump))"
      /usr/bin/hdiutil attach "${download_filename?}" -nobrowse -readonly -mountpoint "${mountpoint?}"
      /usr/sbin/installer -pkg ${mountpoint?}/puppet-agent-*-installer.pkg -target /
      /usr/bin/hdiutil detach "${mountpoint?}"
      rm -f $download_filename
      ;;
    *)
      critical "Unknown filetype: $1"
      exit 1
      ;;
  esac
  if test $? -ne 0; then
    critical "Installation failed"
    exit 1
  fi
}

#Platforms that do not need downloads are in *, the rest get their own entry.
case $platform in
  "archlinux")
    critical "Not got Puppet-agent not supported on Arch yet"
    ;;
  "freebsd")
    critical "Not got Puppet-agent not supported on freebsd yet"
    ;;
  *)
    info "Downloading Puppet $version for ${platform}..."
    case $platform in
      "sles")
        info "SLES platform! Lets get you an RPM..."
        gpg_key="${tmp_dir}/RPM-GPG-KEY-puppet"
        do_download "http://yum.puppetlabs.com/RPM-GPG-KEY-puppet" "$gpg_key"
        rpm --import "$gpg_key"
        rm -f "$gpg_key"
        filetype="noarch.rpm"
        filename="${collection}-release-sles-${platform_version}.noarch.rpm"
        download_url="http://yum.puppetlabs.com/${collection}/${filename}"
        ;;
      "el")
        info "Red hat like platform! Lets get you an RPM..."
        filetype="rpm"
        filename="${collection}-release-el-${platform_version}.noarch.rpm"
        download_url="http://yum.puppetlabs.com/${collection}/${filename}"
        ;;
      "fedora")
        info "Fedora platform! Lets get the RPM..."
        filetype="rpm"
        filename="${collection}-release-fedora-${platform_version}.noarch.rpm"
        download_url="http://yum.puppetlabs.com/${collection}/${filename}"
        ;;
      "debian")
        info "Debian platform! Lets get you a DEB..."
        case $major_version in
          "5") deb_codename="lenny";;
          "6") deb_codename="squeeze";;
          "7") deb_codename="wheezy";;
          "8") deb_codename="jessie";;
          "9") deb_codename="stretch";;
        esac
        filetype="deb"
        filename="${collection}-release-${deb_codename}.deb"
        download_url="http://apt.puppetlabs.com/${filename}"
        ;;
      "ubuntu")
        info "Ubuntu platform! Lets get you a DEB..."
        case $platform_version in
          "12.04") deb_codename="precise";;
          "12.10") deb_codename="quantal";;
          "13.04") deb_codename="raring";;
          "13.10") deb_codename="saucy";;
          "14.04") deb_codename="trusty";;
          "15.04") deb_codename="vivid";;
          "15.10") deb_codename="wily";;
          "16.04") deb_codename="xenial";;
          "16.10") deb_codename="yakkety";;
          "17.04") deb_codename="zesty";;
          "18.04") deb_codename="bionic";;
          "14.10") utopic;;
        esac
        filetype="deb"
        filename="${collection}-release-${deb_codename}.deb"
        download_url="http://apt.puppetlabs.com/${filename}"
        ;;
      "mac_os_x")
        info "OSX platform! Lets get you a DMG..."
        filetype="dmg"
        if test "$version" = "latest"; then
          filename="puppet-agent-latest.dmg"
        else
          filename="puppet-agent-${version}-1.osx${platform_version}.dmg"
        fi
        download_url="http://downloads.puppetlabs.com/mac/${collection}/${platform_version}/x86_64/${filename}"
        ;;
      *)
        critical "Sorry $platform is not supported yet!"
        exit 1
        ;;
    esac

    download_filename="${tmp_dir}/${filename}"

    do_download "$download_url" "$download_filename"

    install_file $filetype "$download_filename"
    ;;
esac

#Cleanup
if test "x$tmp_dir" != "x"; then
  rm -r "$tmp_dir"
fi
