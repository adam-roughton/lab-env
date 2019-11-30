{ 
  sparkDefinition, # see default.nix
  stdenv,
  lib,
  maven,
  xmlstarlet,
  jre_headless,
  jdk,
  coreutils,
  ps,
  gnused,
  nettools,
  runCommand,
  makeWrapper,
  python3,
}:

with sparkDefinition;

let
  scalaVersionMajorMinor = "${lib.versions.majorMinor scalaVersion}";
  hadoopQualifier = if hadoop != null then "without-hadoop" else "hadoop${hadoopVersion}";
  sparkName = "spark-${sparkVersion}-${hadoopQualifier}_${scalaVersionMajorMinor}";
  hadoopResolvedVersion = if hadoop != null then "${hadoop.version}" else hadoopVersion;
  python = if sparkDefinition.python != null then sparkDefinition.python else python3;

  readDirAsList = dir: builtins.map (f: "${dir}/${f}") (builtins.attrNames (builtins.readDir "${dir}"));
  
  spark = stdenv.mkDerivation rec {
    name = "${sparkName}";
    inherit src sparkVersion scalaVersion;
    
    nativeBuildInputs = [ maven jdk makeWrapper xmlstarlet ];
    buildInputs = [ jre_headless ];
    
    pythonVersion = "${python.version}";

    spark-dist-jars = runCommand "${sparkName}-dist-classpath" {} ''
      mkdir -p "$out/jars"
      ${if hadoop != null then
      ''
      IFS=':'
      for c in $(${hadoop}/bin/hadoop classpath --glob 2>/dev/null); do
        echo ln -s $c $out/jars/$(basename $c)  
        ln -sf $c $out/jars/$(basename $c) 
      done
      '' else ""}
    '';

    spark-dist-classpath = readDirAsList "${spark-dist-jars}/jars";

    mavenFlags = "-DskipTests -Pscala-${scalaVersionMajorMinor} -Dhadoop.version=${hadoopVersion} -P${hadoopProfile} ";
    mavenOpts = "-Xmx2g -XX:ReservedCodeCacheSize=512m";

    postUnpack = ''
    patchShebangs $sourceRoot/dev
    patchShebangs $sourceRoot/build
    $sourceRoot/dev/change-scala-version.sh ${scalaVersionMajorMinor}

    xmlstarlet ed -L \
    -u '//_:useZincServer' -v "false" \
    -u '//_:scala.version' -v ${scalaVersion} \
    $sourceRoot/pom.xml
    '';
    
    # inspired by pkgs/applications/networking/cluster/hadoop/default.nix
    dependencies = stdenv.mkDerivation {
      name = "${sparkName}-deps";
      inherit src postUnpack nativeBuildInputs;

      buildPhase = ''
        # `user.home` leaks in via the JVM, 
        # so set it to something else for the build
        mkdir fake-home
        export _JAVA_OPTIONS=-Duser.home=fake-home

        export MAVEN_OPTS="${mavenOpts}"

        while mvn package \
           -Pyarn \
           -Pmesos \
           -Pkubernetes \
           -Phadoop-cloud \
           -Dmaven.repo.local=$out/.m2 ${mavenFlags} \
           -Dmaven.wagon.rto=5000; [ $? = 1 ]; do
          echo "timeout, restart maven to continue downloading"
        done

        rm -rf fake-home
      '';

      # keep only *.{pom,jar,xml,sha1,so,dll,dylib} and delete all ephemeral files with lastModified timestamps inside
      installPhase = ''find $out/.m2 -type f -regex '.+\(\.lastUpdated\|resolver-status\.properties\|_remote\.repositories\)' -delete'';
      outputHashAlgo = "sha256";
      outputHashMode = "recursive";
      outputHash =  "${dependencies-sha256}";
    };

    buildPhase = ''
      # `user.home` leaks in via the JVM, 
      # so set it to something else for the build
      mkdir fake-home
      export _JAVA_OPTIONS=-Duser.home=fake-home

      cp -Rdp ${dependencies}/.m2 .m2
      chmod -R +w .m2

      export JAVA_HOME="${jdk}"
      export MAVEN_OPTS="${mavenOpts}"  

      mvn package \
        --offline \
        -Dmaven.repo.local=$PWD/.m2 \
        ${if hadoop != null then "-Phadoop-provided" else ""
        } ${if withYarn then ''-Pyarn'' else ""
        } ${if withMesos then ''-Pmesos'' else ""
        } ${if withKubernetes then ''-Pkubernetes'' else ""
        } ${if withHadoopCloud then ''-Phadoop-cloud'' else ""
        } ${mavenFlags}
    '';

    installPhase = ''
      export SPARK_HOME=$out/home
      export JAVA_HOME="${jre_headless}"
      mkdir -p "$SPARK_HOME"

      mkdir -p $SPARK_HOME/jars
      cp -dp assembly/target/scala*/jars/* "$SPARK_HOME/jars/"

      ${if withYarn then ''
      mkdir -p "$SPARK_HOME/yarn"
      cp -dp common/network-yarn/target/scala*/spark-*-yarn-shuffle.jar "$SPARK_HOME/yarn"
      '' 
      else "" 
      } 

      # Copy examples and dependencies
      mkdir -p $SPARK_HOME/examples/jars
      mkdir -p $SPARK_HOME/examples/src/main
      for f in examples/scala*/jars/*; do
        name = $(basename "$f")
        if [ ! -f "$SPARK_HOME/jars/$name" ]; then
          cp -dp "$f" "$SPARK_HOME/examples/jars/"
        fi
      done
      cp -rdp "examples/src/main" "$SPARK_HOME/examples/src/" 

      # Copy license and ASF files
      if [ -e "LICENSE-binary" ]; then
        cp -dp "LICENSE-binary" "$SPARK_HOME/LICENSE"
        cp -rdp "licenses-binary" "$SPARK_HOME/licenses"
        cp -dp "NOTICE-binary" "$SPARK_HOME/NOTICE"
      else
        echo "Skipping copying LICENSE files"
      fi

      if [ -e "CHANGES.txt" ]; then
        cp -dp "CHANGES.txt" "$SPARK_HOME"
      fi

      # Copy data files
      cp -rdp "data" "$SPARK_HOME"

      mkdir "$SPARK_HOME/conf"
      cp -dp conf/*.template "$SPARK_HOME/conf"
      cp -dp "README.md" "$SPARK_HOME"
      cp -rdp "bin" "$SPARK_HOME"
      cp -rdp "python" "$SPARK_HOME"
      cp -rdp "sbin" "$SPARK_HOME"
      cat ${
        if log4jProperties != null then 
          log4jProperties.out 
        else 
          "conf/log4j.properties.template"
      } > $SPARK_HOME/conf/log4j.properties

      # based on pkgs/applications/networking/cluster/spark/default.nix
      cat > $SPARK_HOME/conf/spark-env.sh <<-EOF
      export SPARK_HOME="$SPARK_HOME"
      export JAVA_HOME="$JAVA_HOME"
      export PYSPARK_PYTHON="${python}/bin/python"
      export PYSPARK_DRIVER_PYTHON="${python}/bin/python"
      export PYTHONPATH="\$PYTHONPATH:$SPARK_HOME/python/:$SPARK_HOME/python/lib/"
      export SPARK_DIST_CLASSPATH="${lib.concatStringsSep ":" spark-dist-classpath}" 
      EOF

      chmod +x "$SPARK_HOME/conf/spark-env.sh"

      mkdir -p "$out/bin"
      for b in $(find $SPARK_HOME/bin -type f ! -name "*.*"); do
        makeWrapper "$b" "$out/bin/$(basename $b)" \
          --prefix PATH : "${coreutils}/bin/dirname" \
          --set SPARK_HOME $SPARK_HOME \
          --set JAVA_HOME $JAVA_HOME
      done

      for s in $(find $SPARK_HOME/sbin -type f); do
        makeWrapper "$s" "$out/bin/$(basename $s)" \
          --prefix PATH : "${coreutils}/bin/dirname" \
          --prefix PATH : "${ps}/bin/ps" \
          --prefix PATH : "${gnused}/bin/sed" \
          --prefix PATH : "${nettools}/bin/hostname" \
          --set SPARK_HOME $SPARK_HOME \
          --set JAVA_HOME $JAVA_HOME
      done 
    '';

  };

  sparkHome = "${spark}/home";
  spark-jars = readDirAsList "${sparkHome}/jars";

in
  spark // { inherit sparkHome spark-jars; }
