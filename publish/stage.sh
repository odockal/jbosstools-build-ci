  #!/bin/bash
# Script to copy a CI build to staging for QE review
# From Jenkins, call this script 7 times in parallel (&) then call wait to block until they're all done

# TODO: should this script call rsync.sh (for build copy + symlink gen, and for update site copy w/ --del?) instead of using rsync?
# TODO: add support for JBDS staging steps
#  - see https://github.com/jbdevstudio/jbdevstudio-devdoc/blob/master/release_guide/9.x/JBDS_Staging_for_QE.adoc#push-installers-update-site-and-discovery-site
# TODO: create Jenkins job(s)
# TODO: test this !!
# TODO: add verification steps - wget or curl the destination URLs and look for 404s or count of matching child objects
#  - see end of https://github.com/jbdevstudio/jbdevstudio-devdoc/blob/master/release_guide/9.x/JBDS_Staging_for_QE.adoc#push-installers-update-site-and-discovery-site

DESTINATION=tools@filemgmt.jboss.org:/downloads_htdocs/tools # or devstudio@filemgmt.jboss.org:/www_htdocs/devstudio or /qa/services/http/binaries/RHDS
DEST_URL="http://download.jboss.org/jbosstools"
whichID=latest
rawJOB_NAME="jbosstools-\${site}_\${stream}"
sites=""

# can be used to publish a build (including installers, site zips, MD5s, build log) or just an update site folder
usage ()
{
  echo "Usage  : $0 [-DESTINATION destination] -s source_path -t target_path"
  echo ""

  echo "To stage JBT core, coretests, central & earlyaccess"
  echo "   $0 -sites \"site coretests-site central-site earlyaccess-site\" -eclipseReleaseName mars -stream 4.3.mars -vr 4.3.1.CR1a -JOB_NAME jbosstools-build-sites.aggregate.\\\${site}_\\\${stream}"
  echo "To stage JBT discovery.* sites & browsersim-standalone"
  echo "   $0 -sites \"discovery.central discovery.earlyaccess browsersim-standalone\" -eclipseReleaseName mars -stream 4.3.mars -vr 4.3.1.CR1a"
  exit 1
}

if [[ $# -lt 1 ]]; then usage; fi

# read commandline args
while [[ "$#" -gt 0 ]]; do
  case $1 in
    '-sites') sites="${sites} $2"; shift 1;; # site coretests-site central-site earlyaccess-site discovery.central discovery.earlyaccess
    '-eclipseReleaseName') eclipseReleaseName="$2"; shift 1;; # mars
    '-stream') stream="$2"; shift 1;; # 4.3.mars
    '-versionWithRespin'|'-vr') versionWithRespin="$2"; shift 1;; # 4.3.0.CR2b # a, b, c...
    '-DJOB_NAME'|'-JOB_NAME') rawJOB_NAME="$2"; shift 1;;

    '-DESTINATION') DESTINATION="$2"; shift 1;; # override for JBDS publishing, eg., devstudio@filemgmt.jboss.org:/www_htdocs/devstudio or /qa/services/http/binaries/RHDS
    '-DEST_URL')    DEST_URL="$2"; shift 1;; # override for JBDS publishing, eg., https://devstudio.redhat.com

    '-DWORKSPACE'|'-WORKSPACE')      WORKSPACE="$2"; shift 1;; # optional
    '-DID'|'-ID') whichID="$2"; shift 1;; # optionally, set a specific build ID such as 2015-10-02_18-28-18-B124; if not set, pull latest
    *) OTHERFLAGS="${OTHERFLAGS} $1"; shift 0;;
  esac
  shift 1
done

if [[ ! ${WORKSPACE} ]]; then WORKSPACE=${tmpdir}; fi

for site in ${sites}; do
  # evaluate site or stream variables embedded in JOB_NAME
  if [[ ${rawJOB_NAME/\$\{site\}} != ${rawJOB_NAME} ]] || [[ ${rawJOB_NAME/\$\{stream\}} != ${rawJOB_NAME} ]]; then JOB_NAME=$(eval echo ${rawJOB_NAME}); fi

  if [[ ${whichID} == "latest" ]]; then
    ID=""
    ID=$(echo "ls 20*" | sftp ${DESTINATION}/${eclipseReleaseName}/snapshots/builds/${JOB_NAME} 2>&1 | grep "20.\+" | grep -v sftp | sort | tail -1); ID=${ID%%/*}
    # echo "${DESTINATION}/${eclipseReleaseName}/snapshots/builds/${JOB_NAME} :: ID = $ID" | egrep "${JOB_NAME}|${site}|${ID}|ERROR"
  fi
  grepstring="${JOB_NAME}|${site}|${ID}|ERROR|${versionWithRespin}"
  DEST_URLs=""

  if [[ ${ID} ]]; then
    if [[ ${site} == "site" ]]; then sitename="core"; else sitename=${site/-site/}; fi
    echo "Latest build for ${sitename} (${site}): ${ID}" | egrep "${grepstring}"
    tmpdir=`mktemp -d` && mkdir -p $tmpdir && pushd $tmpdir >/dev/null
      # echo "+ rsync -arz --rsh=ssh --protocol=28 ${DESTINATION}/${eclipseReleaseName}/snapshots/builds/${JOB_NAME}/${ID}/* ${tmpdir}/" | egrep "${grepstring}"
      rsync -arz --rsh=ssh --protocol=28 ${DESTINATION}/${eclipseReleaseName}/snapshots/builds/${JOB_NAME}/${ID}/* ${tmpdir}/
      # copy build folder
      echo "mkdir jbosstools-${versionWithRespin}-build-${sitename}" | sftp ${DESTINATION}/${eclipseReleaseName}/staging/builds/
      # echo "+ rsync -arz --rsh=ssh --protocol=28 ${tmpdir}/* ${DESTINATION}/${eclipseReleaseName}/staging/builds/jbosstools-${versionWithRespin}-build-${sitename}/${ID}/" | egrep "${grepstring}"
      rsync -arz --rsh=ssh --protocol=28 ${tmpdir}/* ${DESTINATION}/${eclipseReleaseName}/staging/builds/jbosstools-${versionWithRespin}-build-${sitename}/${ID}/
      DEST_URLs="${DEST_URLs} ${DEST_URL}/${eclipseReleaseName}/staging/builds/jbosstools-${versionWithRespin}-build-${sitename}/"
      # symlink latest build
      ln -s ${ID} latest; rsync -aPrz --rsh=ssh --protocol=28 ${tmpdir}/latest ${DESTINATION}/${eclipseReleaseName}/staging/builds/jbosstools-${versionWithRespin}-build-${sitename}/
      DEST_URLs="${DEST_URLs} ${DEST_URL}/${eclipseReleaseName}/staging/builds/jbosstools-${versionWithRespin}-build-${sitename}/latest/"
      # copy update site
      if [[ -d ${tmpdir}/all/repo/ ]]; then
        echo "mkdir ${sitename}" | sftp ${DESTINATION}/${eclipseReleaseName}/staging/updates/
        #echo "+ rsync -arz --rsh=ssh --protocol=28 ${tmpdir}/all/repo/* ${DESTINATION}/${eclipseReleaseName}/staging/updates/${sitename}/${versionWithRespin}/" | egrep "${grepstring}"
        rsync -arz --rsh=ssh --protocol=28 ${tmpdir}/all/repo/* ${DESTINATION}/${eclipseReleaseName}/staging/updates/${sitename}/${versionWithRespin}/
        DEST_URLs="${DEST_URLs} ${DEST_URL}/${eclipseReleaseName}/staging/updates/${sitename}/${versionWithRespin}/"
      fi
    popd >/dev/null
    rm -fr $tmpdir
    echo "DONE: ${JOB_NAME} :: ${site} :: ${ID}" | egrep "${grepstring}"
    for du in ${DEST_URLs}; do echo "${du}" | egrep "${grepstring}"; done
    echo ""
  else
    echo "ERROR: no latest build found for ${JOB_NAME} :: ${site} :: ${ID}" | egrep "${grepstring}"
  fi
done
