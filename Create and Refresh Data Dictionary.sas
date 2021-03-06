/********************************************
CLIENT-TPA VARIABLE AVAILABILITY

Purpose: 
(1) Determine which variables exist in
    all client-TPA datasets, namely:
    * Finclms
    * Claims
    * Claimsrx
    * Member
    * Eligibility
    * Provider
(2) Using data from (1), determine
    which client-TPA's have what
    core datasets
(3) Provide dataset- and aggregate-
    level metadata on on each
    variable (e.g., type, length,
    index use) as well as non-null
    example values.
(4) Insert previously curated definitions
    (see "Update Definitions.sas")
    at the aggregate level.
    
USAGE

  You will first need to either
  add LET statements or else add
  a user prompt for the user-
  defined variables.

********************************************/

OPTIONS THREADS SASTRACE = ',,,sa' SASTRACELOC = SASLOG NOSTSUFFIX;

/* turn off display of outputs/notes */
%MACRO ods_off;
    ODS EXCLUDE ALL;
    ODS NORESULTS;
    OPTIONS NONOTES;
%MEND;
 
/* re-enable display of outputs/notes */
%MACRO ods_on;
    ODS EXCLUDE NONE;
    ODS RESULTS;
    OPTIONS NOTES;
%MEND;

%ods_off

/* Refresh the client-TPA crosswalks from PDW to EDW */
%INCLUDE "/sasprod/ca/sasdata/Client_TPA_Availability/Code and Source Files/Client_TPA_Availability_Lists.sas";

/* Automated variables and libnames */ 
%LET today = %SYSFUNC(TODAY(), DATE9.);
%LET _today=%SYSFUNC(TODAY());

LIBNAME myfiles "/sasprod/users/&user_prompt./data_dict" ;
LIBNAME sasdata "/sasprod/ca/sasdata/Client_TPA_Availability";
LIBNAME pubdata "/sasprod/dg/shared/PDW Data Dictionary/Code";
LIBNAME pubarxiv "/sasprod/dg/shared/PDW Data Dictionary/Archive";
%LET priordict = pubdata.all_var_by_dataset_&priorrundt_prompt.;
%LET newdict = pubdata.all_var_by_dataset_&today.;
    /* Filename of the previously-created dict. */

%MACRO dict_def;

    /* Sort and back up the current data dictionary
       definitions to a new archived dataset. */
    PROC SORT DATA=pubdata.definition_source;
        BY DESCENDING Updated Core_Dataset Variable;
    RUN;
    
    PROC SQL NOPRINT;

        /* New definitions missing an Updated date
           will have this date set as today. */

        UPDATE pubdata.definition_source
        SET Updated = INPUT("&today.", DATE9.)
        WHERE Updated IS NULL
        ;

        SELECT CATS(COUNT(Updated), "(", Core_Dataset, ")")
        INTO :new_records SEPARATED BY ', '
        FROM pubdata.definition_source
        WHERE PUT(Updated, DATE9.) = PUT(INPUT("&today.", DATE9.), DATE9.)
        GROUP BY Core_Dataset
        ;

        %PUT New or updated definitions: &new_records..;

    QUIT;

    DATA pubarxiv.definition_source_&today.;
        SET pubdata.definition_source;
    RUN;

%MEND dict_def;
%dict_def

/***************************************
SECTION 1

Create combined list of all PDW 
client-TPA's
***************************************/
DATA myfiles.all_pdw
        (RENAME=(
            PDW_Client_Name=Client_Name
            PDW_TPA_Name=TPA_Name));
    SET sasdata.all_pdw;
RUN;
/***************************************
SECTION 2

Determine Client Variable Availability
in all PDW datasets.

***************************************/
%MACRO all_clients(dataset);
    
    /* create a counter variable
    based on the number of client-tpa's
    in the dataset */
    PROC SQL NOPRINT;
        SELECT CATS(COUNT(*))
        INTO :count
        FROM &dataset.
        ;
    QUIT;

    /* Set variables to be used when
       auto-creating libnames */
    PROC SQL;
        SELECT
            client_name
            , tpa_name
            , CATS('lref', ref_id)
            , path
        INTO
            :client_1-:client_&count.
            , :tpa_1-:tpa_&count.
            , :libref_1-:libref_&count.
            , :path_1-:path_&count.
        FROM &dataset.
        ;
    QUIT;

    /* Iterate through every client-TPA directory in PDW */
    %DO i=1 %TO &count.;
        LIBNAME &&libref_&i. "&&Path_&i.." ACCESS = READONLY;
        
        /* Delete intermediate datasets from prior iterations if applicable */
        %IF %SYSFUNC(EXIST(variable_matrix))
        %THEN
            %DO;
                PROC DATASETS LIBRARY=WORK MEMTYPE=DATA NOLIST;
                    DELETE
                        variable_matrix
                        matrix_:
                        ;
                RUN;
            %END;

        %PUT; %PUT;
        %PUT (%SYSFUNC(TIME(), TIMEAMPM11.)) Client-TPA &&client_&i.. - &&tpa_&i..: Loop &i./%CMPRES(&count.).;

        /* Create list of dataset variables */
        %MACRO CONTENTS_MATRIX(pdw_data, pdw_data_out);
            /* Only execute if the core dataset exists */
            %IF %SYSFUNC(EXIST(&&libref_&i...&pdw_data.))
            %THEN
                %DO;
                    
                    %PUT Gathering %UPCASE(&pdw_data.) variable data.;

                    PROC CONTENTS DATA = &&libref_&i...&pdw_data. 
                        MEMTYPE = DATA    
                        OUT = &pdw_data_out. NOPRINT;
                    RUN;

                    %MACRO freq;
                        PROC SQL NOPRINT;
                            SELECT CATS(COUNT(name))
                            INTO :vcount
                            FROM &pdw_data_out.
                            ;

                            SELECT name
                            INTO :var_list SEPARATED BY " "
                            FROM &pdw_data_out.
                            ;
                        QUIT;

                        %PUT (%SYSFUNC(TIME(), TIMEAMPM11.)) Compiling a variable-value frequency table for %CMPRES(&vcount.) variables.;

                        %IF %SYSFUNC(CATS(&vcount.)) = %SYSFUNC(CATS(0))
                        %THEN
                            %DO;
                                %PUT No variables located, so no frequency table was created. ;
                            %END;
                        %ELSE 
                            %DO;
                                
                                PROC SQL NOPRINT;
                                    SELECT
                                        varnum
                                        , CATS("COUNT("
                                             , name
                                             , ")/COUNT(*)"
                                             )
                                    INTO :varnums SEPARATED BY ", "
                                        , :query SEPARATED BY ", "
                                    FROM &pdw_data_out.
                                    ;
                                
                                    CREATE TABLE pcounts AS
                                        SELECT &query.
                                        FROM &&libref_&i...&pdw_data.
                                    ;

                                    INSERT INTO pcounts
                                    VALUES (&varnums.)
                                    ;

                                QUIT;
                                
                                PROC TRANSPOSE
                                    DATA = pcounts
                                    OUT =  pcounts_t
                                    ;
                                RUN;

                                %PUT (%SYSFUNC(TIME(), TIMEAMPM11.)) Extracting a sample value for each of the %CMPRES(&vcount.) variables.;
                                
                                /* Subset the core dataset for speed and create
                                   a local copy to avoid lock- and io-related
                                   delays. Choose enough observations to ensure
                                   most variables have at least one non-null 
                                   value in the subset, but avoid >10K records
                                   if possible. 1+M record datasets will take
                                   AT LEAST a couple of minutes EACH. */
                                DATA myfiles.example_source_lref&i.;
                                    SET &&libref_&i...&pdw_data. 
                                        (OBS=10000);
                                RUN;

                                %DO ex=1 %TO &vcount.;

                                    %LET iter_variable = %SCAN(&var_list., &ex.);
                                    
                                    /* Choose the first non-null value of
                                       the chosen variable, else return nothing. */
                                    DATA myfiles.var_example_&ex.
                                            (KEEP=Variable Example);
                                        SET myfiles.example_source_lref&i.
                                            (KEEP=&iter_variable.
                                             WHERE=(NOT MISSING(&iter_variable.))
                                             OBS=1
                                            );
                                        FORMAT
                                            Variable $32.
                                            Example $200.
                                        ;    
                                        Variable = "&iter_variable.";
                                        Example = CATS(&iter_variable.);
                                    RUN;

                                %END;
                                
                                DATA myfiles.var_examples;
                                    INFORMAT
                                        Variable $32.
                                        Example $200.
                                    ;
                                    SET myfiles.var_example_:;
                                    FORMAT
                                        Variable $32.
                                        Example $200.
                                    ;
                                RUN;
                                

                                PROC SQL NOPRINT;
                                    CREATE TABLE
                                            &pdw_data_out._final AS
                                        SELECT
                                            "&&client_&i.." AS Client_Name
                                            , "&&tpa_&i.." AS TPA_Name
                                            , "&&path_&i.." AS Path
                                            , LOWCASE(init.memname) AS Core_Dataset
                                            , LOWCASE(init.name) AS Variable
                                            , CASE
                                                WHEN init.type = 1
                                                THEN "Numeric"
                                                WHEN init.type = 2
                                                THEN "Character"
                                              END AS Type
                                            , init.Length
                                            , init.Format
                                            , init.idxusage AS Index_Usage
                                            , pcounts_t.Col1 AS Non_null
                                            , v.Example

                                        FROM &pdw_data_out. AS init
                                        LEFT JOIN pcounts_t
                                            ON init.varnum = pcounts_t.COL2
                                        LEFT JOIN myfiles.var_examples AS v
                                            ON init.name = v.variable
                                    ;
                                QUIT;

                                PROC SORT DATA = &pdw_data_out._final;
                                    BY Core_Dataset Variable;
                                RUN;

                                PROC DATASETS LIBRARY=WORK MEMTYPE=DATA NOLIST;
                                    DELETE
                                        pcounts:
                                        varnum:
                                        query:
                                    ;
                                RUN;
                                
                                PROC DATASETS LIBRARY=myfiles MEMTYPE=DATA NOLIST;
                                    DELETE
                                        var_example_:
                                        var_examples
                                        example_source_lref:
                                    ;
                                RUN;
                                
                            %END;
                        
                    %MEND freq;
                    %freq

                    /* Create variable list if it doesn't exist;
                       otherwise, append the next dataset's
                       variable list */
                    %IF %SYSFUNC(EXIST(variable_matrix))
                    %THEN
                        %DO;
                            PROC DATASETS;    
                               APPEND BASE = variable_matrix     
                                  DATA = &pdw_data_out._final
                                  ;
                            RUN;
                        %END;
                    %ELSE
                        %DO;
                            DATA variable_matrix;
                                SET &pdw_data_out._final;
                                BY Core_Dataset Variable;
                            RUN;
                        %END;
                %END;
            %ELSE %PUT For client-TPA &&client_&i.. - &&tpa_&i..: %UPCASE(&pdw_data.) does not exist or is unavailable.;
        %MEND;
        
        /* Create variable lists for all core datasets */
        %CONTENTS_MATRIX(member, matrix_mem);
        %CONTENTS_MATRIX(eligibility, matrix_elig);
        %CONTENTS_MATRIX(provider, matrix_prov);
        %CONTENTS_MATRIX(finclms, matrix_finclms);
        %CONTENTS_MATRIX(claims, matrix_claims);
        %CONTENTS_MATRIX(claimsrx, matrix_claimsrx);
        
        %IF %SYSFUNC(EXIST(variable_matrix))
        %THEN
            %DO;
                /* uniquely rename the client-TPA dataset */
                PROC SQL; 
                    CREATE TABLE myfiles.af_&&libref_&i.. AS 
                        SELECT *
                        FROM variable_matrix
                        ;
                QUIT;

                /* Delete the intermediate datasets */
               PROC DATASETS LIBRARY=WORK MEMTYPE=DATA NOLIST;
                    DELETE
                        variable_matrix
                        matrix_:
                    ;
                RUN;
            %END;
    %END;
    
    %PUT Combining all client-TPA level datasets.;
    DATA myfiles.all_var_by_dataset_init;
        INFORMAT /* must precede SET to avoid truncating */
            Client_Name $50.
            TPA_Name $50.
            Path $100.
            Core_Dataset $32.
            Variable $32.
            Type $9.
            Length 5.
            Format $32.
            Index_Usage $50.
            Non_null 9.8
            Example $200.
            ;
        SET myfiles.af_:;
        FORMAT
            Client_Name $50.
            TPA_Name $50.
            Path $100.
            Core_Dataset $32.
            Variable $32.
            Type $9.
            Length 5.
            Format $32.
            Index_Usage $50.
            Non_null 9.8
            Example $200.
            ;

    RUN;
    
    %PUT Recording variable definition update dates.;
    PROC SQL;
        CREATE TABLE myfiles.all_var_by_dataset_&today. AS
            SELECT
                a.Client_Name
                , a.TPA_Name
                , a.Path
                , a.Core_Dataset
                , a.Variable
                , a.Type
                , a.Length
                , a.Format
                , a.Index_Usage
                , a.Non_null
                , a.Example
                , CASE
                    WHEN r.Variable_Added IS NOT NULL
                      THEN r.Variable_Added
                    ELSE PUT(INPUT("&today.", DATE9.), DATE9.)
                  END AS Variable_Added
            FROM myfiles.all_var_by_dataset_init AS a
            LEFT JOIN &priordict. AS r
                ON a.Path = r.Path
                    AND a.Core_Dataset = r.Core_Dataset
                    AND a.Variable = r.Variable
            ;
    QUIT;

    /* Create timestamped copies of the dictionary
       source data for later reference. */
    /* Archiving enables tracking of
       when new variables are added to a given
       client-TPA-dataset. Copies are strictly
       kept in the shared directory and
       archive.
       */

    DATA pubdata.all_var_by_dataset_&today.;
        SET myfiles.all_var_by_dataset_&today.;
    RUN;

    DATA pubarxiv.all_var_by_dataset_&today.;
        SET myfiles.all_var_by_dataset_&today.;
    RUN;
    
    PROC DATASETS LIBRARY=myfiles MEMTYPE=DATA NOLIST;
        DELETE
            af_:
        ;
    RUN;

%MEND;
%all_clients(myfiles.all_pdw)

/***************************************
SECTION 3

Create dictionaries for each
core dataset using the master
variable availability dataset.

***************************************/

%MACRO dataset_dict(core_dataset);

    PROC SQL NOPRINT;
        CREATE TABLE _&core_dataset._core_&today. AS 
            SELECT
                LOWCASE(Core_Dataset) AS Core_Dataset
                , LOWCASE(Variable) AS Variable
                , CASE
                    WHEN Type = "NUMERIC"
                    THEN 1
                    ELSE -1 /* character */
                  END AS Type
                , Length
                , CASE
                    WHEN Index_Usage = "NONE"
                    THEN -1
                    ELSE 1
                  END AS Index_Usage
                , Non_null
                , Client_Name
                , TPA_Name
                , Path
            FROM &newdict.
            WHERE LOWCASE(Core_Dataset) =
                "&core_dataset."
            ;

    QUIT;

    PROC SORT DATA = _&core_dataset._core_&today.;
        BY Variable Client_Name TPA_Name;
    RUN;

    /* Count subsets of client-TPA's
       from the set of client-TPA's with
       the current core dataset */
    PROC SQL NOPRINT;

        SELECT CATS(COUNT(DISTINCT path))
        INTO :aco_count
        FROM _&core_dataset._core_&today.
        WHERE path CONTAINS 'ngaco'
            OR path CONTAINS 'mssp'
        ;

        SELECT CATS(COUNT(DISTINCT path))
        INTO :aldr_count
        FROM _&core_dataset._core_&today.
        WHERE LOWCASE(TPA_Name) CONTAINS 'aldera'
        ;

        SELECT CATS(COUNT(DISTINCT path))
        INTO :all_count
        FROM _&core_dataset._core_&today.
        ;
    
        CREATE TABLE _&core_dataset._analysis_&today. AS 
            SELECT
                Core_Dataset
                , Variable
                , CASE
                    WHEN SUM(Type) = COUNT(Type)
                      AND SUM(Type) > 0
                      THEN "Always numeric among client-TPA's in &core_dataset.."
                    WHEN SUM(Type) = - COUNT(Type)
                      AND SUM(Type) < 0
                      THEN "Always character among client-TPA's in &core_dataset.."
                    WHEN SUM(Type) > 0
                      THEN "Usually numeric among client-TPA's in &core_dataset.."
                    WHEN SUM(Type) < 0
                      THEN "Usually character among client-TPA's in &core_dataset.."
                    ELSE "Equally likely to be character/numeric among client-TPA's in &core_dataset.."
                  END AS Type
                , CASE
                    WHEN SUM(Index_Usage) = COUNT(Index_Usage)
                      AND SUM(Index_Usage) > 0
                      THEN "Always used as an index/key among client-TPA's in &core_dataset.."
                    WHEN SUM(Index_Usage) = - COUNT(Index_Usage)
                      AND SUM(Index_Usage) < 0
                      THEN "Never used as an index/key among client-TPA's in &core_dataset.."
                    WHEN SUM(Index_Usage) > 0
                      THEN "Usually used as an index/key among client-TPA's in &core_dataset.."
                    WHEN SUM(Index_Usage) < 0
                      THEN "Rarely used as an index/key among client-TPA's in &core_dataset.."
                    ELSE "Equally likely to be used as an index/key among client-TPA's in &core_dataset.."
                  END AS Index_Usage
                , MIN(Length)
                    AS min_length
                , MAX(Length)
                    AS max_length
                , CATS(COUNT(DISTINCT Path), '/', &all_count.)
                    AS fraction_client_tpa
                , CATS(COUNT(DISTINCT
                    CASE
                      WHEN LOWCASE(Path) CONTAINS 'mssp'
                           OR LOWCASE(Path) CONTAINS 'ngaco'
                    THEN Path
                    END), '/', &aco_count.)
                  AS fraction_mssp_ngaco
                , CATS(COUNT(DISTINCT
                    CASE WHEN LOWCASE(TPA_Name) CONTAINS 'aldera'
                    THEN Path
                    END), '/', &aldr_count.)
                  AS fraction_aldera
            FROM _&core_dataset._core_&today.
            GROUP BY
                Core_Dataset
                , Variable
            ;
    QUIT;

    %LET analysis = _&core_dataset._analysis_&today.;
    %LET dict = myfiles.&core_dataset._dict_&today.;
    %LET avail = myfiles.&core_dataset._avail_&today.;

    /* Add source file's descriptions
       at the dataset-variable level. */
    PROC SQL;
        CREATE TABLE &dict. AS
            SELECT
                LOWCASE(a.Core_Dataset) AS Core_Dataset
                , LOWCASE(a.Variable) AS Variable
                , s.Description
                , a.Type
                , a.Index_Usage
                , a.min_length
                , a.max_length
                , a.fraction_client_tpa
                , a.fraction_mssp_ngaco
                , a.fraction_aldera
                , s.Updated
            FROM &analysis. AS a
            LEFT JOIN pubdata.definition_source AS s
                ON LOWCASE(a.variable) = LOWCASE(s.variable)
                    AND LOWCASE(a.Core_Dataset) = LOWCASE(s.Core_Dataset)
            ;
    QUIT;
        
    PROC SQL;
        CREATE TABLE &avail. AS
            SELECT
                LOWCASE(Core_Dataset) AS Core_Dataset
                , Path
                , Client_Name
                , TPA_Name
                , LOWCASE(Variable) AS Variable
                , Example
                , Non_null
                , Type
                , Length
                , Index_Usage
                , Variable_Added
                , CASE
                    WHEN LOWCASE(TPA_Name)
                        CONTAINS "aldera"
                    THEN 1
                    ELSE 0
                  END AS is_aldera
                , CASE
                    WHEN Path CONTAINS "mssp"
                        OR Path CONTAINS "ngaco"
                    THEN 1
                      ELSE 0
                  END AS is_mssp_ngaco
            FROM &newdict.
            WHERE LOWCASE(Core_Dataset) =
                "&core_dataset."
            ;
    QUIT;
    
%MEND;

%dataset_dict(eligibility)
%dataset_dict(member)
%dataset_dict(provider)
%dataset_dict(claims)
%dataset_dict(finclms)
%dataset_dict(claimsrx)

%MACRO combined_dataset_dict;
    /* Create combined dictionary and export it */
    DATA myfiles.final_combined_dict_&today.;
        SET myfiles.eligibility_dict_&today.
            myfiles.member_dict_&today.
            myfiles.provider_dict_&today.
            myfiles.claims_dict_&today.
            myfiles.finclms_dict_&today.
            myfiles.claimsrx_dict_&today.
            ;
    RUN;

    DATA myfiles.final_combined_avail_&today.;
        SET myfiles.eligibility_avail_&today.
            myfiles.member_avail_&today.
            myfiles.provider_avail_&today.
            myfiles.claims_avail_&today.
            myfiles.finclms_avail_&today.
            myfiles.claimsrx_avail_&today.
            ;
    RUN;

    /* Check % populated rates for variable definitions */
    PROC SQL NOPRINT;

           CREATE TABLE temp AS
                SELECT DISTINCT 
                      core_dataset
                      , variable
                      , description
                      , 1.0* INPUT(SUBSTR(fraction_client_tpa, 1, FIND(fraction_client_tpa, "/")-1), 2.2)
                           /INPUT(SUBSTR(fraction_client_tpa, FIND(fraction_client_tpa, "/")+1), 2.2)
                           AS frac
                FROM myfiles.final_combined_dict_&today.
                WHERE SUBSTR(variable, 1, 1) <> "_"
                      AND CALCULATED frac >= .6
                ;
           
           SELECT
                core_dataset
                , CATS(core_dataset, "(", COUNT(description)/COUNT(*), ")") as pop
           INTO :cd, :pop SEPARATED BY " "
           FROM temp
           WHERE frac >=.6
           GROUP BY core_dataset
           ;

     QUIT;

     %PUT &pop.;

    PROC SORT DATA = myfiles.final_combined_dict_&today.;
        BY Core_Dataset Variable;
    RUN;

    PROC SORT DATA = myfiles.final_combined_avail_&today.;
        BY Core_Dataset Variable Client_Name TPA_Name;
    RUN;

    PROC EXPORT
        DATA= myfiles.final_combined_dict_&today.
        OUTFILE= "/sasprod/dg/shared/PDW Data Dictionary/Archive/PDW Data Dictionary_&today..xlsx"
        DBMS = xlsx
        REPLACE
        ;
        SHEET='Dictionary'
        ;
    RUN;

    PROC EXPORT
        DATA= myfiles.final_combined_avail_&today.
        OUTFILE= "/sasprod/dg/shared/PDW Data Dictionary/Archive/PDW Data Dictionary_&today..xlsx"
        DBMS = xlsx
        REPLACE
        ;
        SHEET='Availability'
        ;
    RUN;

    PROC DATASETS LIBRARY=myfiles MEMTYPE=DATA NOLIST;
        DELETE
            eligibility_:
            member_:
            provider_:
            claims_:
            finclms_:
            claimsrx_:
            final_combined_:
        ;
    RUN;
%MEND;
%combined_dataset_dict

