# Builder for JupyterLab based lab-envs
{
  name,
  pkgs,
  spark, # for now assume all labs are based on Spark
  pythonPackages
}:

let
  jupyterWithProject = builtins.fetchGit {
    url = https://github.com/tweag/jupyterWith;
    rev = "1176b9e8d173f2d2789705ad55c7b53a06155e0f";
  };

  jupyterWith = import jupyterWithProject {
    pkgs = import pkgs.path { 
      overlays = [ (import "${jupyterWithProject}/nix/python-overlay.nix") ];
    };
  };

  ammonite-path = jarPath: "os.Path(\"${jarPath}\")";

  almond = pkgs.callPackage ./almond { scalaVersion = spark.scalaVersion; }; 

  # overwrite the root logging level to match the spark-shell repl level
  spark-scala-kernel-log4j-properties = pkgs.runCommand "spark-kernel-log4j-properties" {} ''
  mkdir -p $out/conf
  REPL_LOG_LEVEL=$(sed -n 's:log4j.logger.org.apache.spark.repl.Main=\(.*\):\1:p' ${spark.sparkHome}/conf/log4j.properties)
  sed "s:log4j.rootCategory=\(.*\)$:log4j.rootCategory=$REPL_LOG_LEVEL, console:" \
    < ${spark.sparkHome}/conf/log4j.properties \
    > $out/log4j.properties
  '';

  spark-scala-kernel = pkgs.callPackage ./kernels/almond {
    inherit almond;
    displayName = "Spark ${spark.sparkVersion} (Scala ${spark.scalaVersion})";
    predefCode = ''
      interp.load.cp(Seq(${
         (pkgs.lib.concatMapStringsSep "," ammonite-path) 
         (spark.spark-jars ++ spark.spark-dist-classpath ++ [ "${spark-scala-kernel-log4j-properties}/" ])
       }));
    '';
  };

  pyspark-kernel = jupyterWith.kernels.iPythonWith {
    name = "pyspark-${spark.sparkVersion}";
    packages = p: (pythonPackages p) ++ [ 
      p.ipykernel.overridePythonAttrs(oldAttrs: {
        makeWrapperArgs = [ 
          "--prefix PYTHONPATH : ${spark.sparkHome}/python/" 
          "--prefix PYTHONPATH : ${spark.sparkHome}/python/lib/py4j*zip"
        ];
      })  
    ];
  };

  spark-env = ''
  source ${spark.sparkHome}/conf/spark-env.sh
  '';  

  # lab definition
  lab = jupyterWith.jupyterlabWith {
    kernels = [ pyspark-kernel spark-scala-kernel ];
  };

  # docker image for running the lab outside of nix
  labDockerImageDefinition = { repo, buildId }:
  let
    sparkLabDockerEntrypoint = pkgs.writeScript "spark-lab-entrypoint.sh" ''
      #!/${pkgs.stdenv.shell}
      ${spark-env}
      export PATH=$PATH:${spark}/bin
      exec "$@"
    '';

    jupyterConfigDocker = pkgs.writeText "jupyter-config.py" ''
    c = get_config()

    c.NotebookApp.ip = '0.0.0.0' # listen on all IPs
    c.NotebookApp.allow_root = True # allow the notebook to run under the root user
    c.NotebookApp.token = ''' # disable authentication
    c.NotebookApp.open_browser = False # We're running Jupyter inside docker, so don't open a browser
    '';
  in {
    imageName = "${repo}:${buildId}";
    image = pkgs.dockerTools.buildImage {
        name = repo;
        tag = buildId;
        contents = with pkgs; [ lab glibcLocales bash coreutils ];
        config = {
           Env = [
             "LOCALE_ARCHIVE=${pkgs.glibcLocales}/lib/locale/locale-archive"
             "LANG=en_US.UTF-8"
             "LANGUAGE=en_US:en"
             "LC_ALL=en_US.UTF-8"
             "SPARK_LOCAL_IP=0.0.0.0"
             "SPARK_LOG_DIR=/data/spark-work-dir/logs"
             "SPARK_WORKER_DIR=/data/spark-work-dir"
             "SHELL=${pkgs.bash}/bin/bash" 
           ];
           Entrypoint = [ sparkLabDockerEntrypoint ]; 
           CMD = [ "/bin/jupyter-lab" "--config" "${jupyterConfigDocker}" ];
           WorkingDir = "/data";
           ExposedPorts = {
             "8888" = {};
           };
           Volumes = {
             "/data" = {};
           };
         };
        runAsRoot = ''
        #!${pkgs.bash}/bin/bash
        ${pkgs.dockerTools.shadowSetup}
        ln -s ${spark}/home /spark
        '';
      };
    };

in
  lab.overrideAttrs(oldAttrs: {
    inherit name;
    mkDockerImage = null;
    passthru = {
      env = oldAttrs.passthru.env.overrideAttrs(oldEnvAttrs: {
        name = "lab-env-shell";
        buildInputs = oldEnvAttrs.buildInputs ++ [ spark ];
        shellHook = oldEnvAttrs.shellHook + spark-env;
      }); 
    };
  }) // {
    dockerImageDefinitions = [ labDockerImageDefinition ];
  }


