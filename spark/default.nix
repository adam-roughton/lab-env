{ callPackage, lib }:
let
  scala212 = "2.12.8";
  scala211 = "2.11.12";
  scalaDefaultVersion = scala212;
  hadoopDefaultVersion = "2.9.2";

 find-dependency-sha = { sparkVersion, scalaVersionMajorMinor, hadoopVersion }:
  assert builtins.pathExists ./version-shas.json;

  let
    depSpecs = builtins.fromJSON (builtins.readFile ./version-shas.json);
    toLookupKV = builtins.map(depSpec: {
      name = "${depSpec.spark}_${depSpec.scala}_${depSpec.hadoop}"; 
      value = "${depSpec.sha256}"; 
    });
    shaLookup = builtins.listToAttrs (toLookupKV depSpecs); 
  in shaLookup."${sparkVersion}_${scalaVersionMajorMinor}_${hadoopVersion}" 
    or (abort "No default sha256 entry found for the version combination: { spark: ${sparkVersion}, scala: ${scalaVersionMajorMinor}, hadoop: ${hadoopVersion} }. Manually specify the sha256 attribute within the mkSparkDist function.");

 mkSparkDist = {
    src ? builtins.fetchGit {
      url = "https://github.com/apache/spark";
      ref = "v${sparkVersion}";
    },
    sparkVersion,
    scalaVersion ? scalaDefaultVersion,
    hadoop ? null,
    hadoopVersion ? if hadoop != null then "${hadoop.version}" else hadoopDefaultVersion,
    hadoopProfile ? (
      let 
        hadoopMajorMinor = lib.versions.majorMinor hadoopVersion;
      in
      (if lib.versionAtLeast hadoopMajorMinor "3.2" then 
        "hadoop-3.2" 
      else 
        (if lib.versionAtLeast hadoopMajorMinor "2.7" then 
           "hadoop-2.7" 
         else 
           "hadoop-2.6"
        )
      )
    ),
    dependencies-sha256 ? find-dependency-sha { 
      inherit sparkVersion hadoopVersion; 
      scalaVersionMajorMinor = "${lib.versions.majorMinor scalaVersion}";
    },
    withYarn ? true,
    withMesos ? false,
    withHadoopCloud ? false,
    withKubernetes ? false,
    extraDriverJars ? [],
    extraSparkJars ? [],
    log4jProperties ? null,
    python ? null 
  }: callPackage ./spark-builder.nix {
    sparkDefinition = { 
      inherit src dependencies-sha256 sparkVersion scalaVersion 
      hadoopVersion hadoop withYarn withMesos withHadoopCloud 
      hadoopProfile withKubernetes extraDriverJars 
      extraSparkJars log4jProperties python; 
    };
  };

in { inherit mkSparkDist scala212 scala211; }
