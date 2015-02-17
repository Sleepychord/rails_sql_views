module RailsSqlViews
  module ConnectionAdapters # :nodoc:
    module SchemaStatements

      # Create a materialized view
      # The +options+ hash can include the following keys:
      # [<tt>:check_option</tt>]
      # [<tt>:primary_key</tt>]
      # [<tt>:refresh_schedule</tt>]
      #   If refresh schedule is given, job is scheduled to refresh the materialized view
      #   and email SOMPROG with any refresh errors
     def create_materialized_view(name, select_query, options={})
        return unless supports_materialized_views?

        view_definition = ViewDefinition.new(self, select_query)

        if block_given?
          yield view_definition
        end

        create_sql = "CREATE MATERIALIZED VIEW #{quote_table_name(name)} "
        create_sql << 'PCTFREE 0 PCTUSED 0 COMPRESS FOR OLTP NOLOGGING REFRESH COMPLETE ON DEMAND '
        create_sql << "AS #{view_definition.select_query}"
        create_sql << " WITH #{options[:check_option]} CHECK OPTION" if options[:check_option]
        execute create_sql

        if options[:primary_key]
          create_primary_key_for_mv name, options[:primary_key]
        end
        
        if options[:refresh_schedule]
          create_mv_refresh_job name, options[:refresh_schedule]
        end
      end

      # Create a view.
      # The +options+ hash can include the following keys:
      # [<tt>:check_option</tt>]
      #   Specify restrictions for inserts or updates in updatable views. ANSI SQL 92 defines two check option
      #   values: CASCADED and LOCAL. See your database documentation for allowed values.
      # [<tt>:force</tt>]
      #   If true, explicitly drop the view before running the create query
      # [<tt>:primary_key</tt>]
      #   If present, create a primary key for the view using this value
      def create_view(name, select_query, options={})
        if supports_views?
          view_definition = ViewDefinition.new(self, select_query)
          
          if block_given?
            yield view_definition
          end

          if options[:force]
            drop_view(name) rescue nil
          end

          create_sql = "CREATE VIEW "
          create_sql << "#{quote_table_name(name)} "
          if supports_view_columns_definition? && !view_definition.to_sql.blank?
            create_sql << "("
            create_sql << view_definition.to_sql
            create_sql << ") " 
          end
          create_sql << "AS #{view_definition.select_query}"
          create_sql << " WITH #{options[:check_option]} CHECK OPTION" if options[:check_option]
          execute create_sql
        end

        if options[:primary_key]
          create_primary_key_for_view name, options[:primary_key]
        end
      end
      
      # Create or replace a view.
      # The +options+ hash can include the following keys:
      # [<tt>:check_option</tt>]
      #   Specify restrictions for inserts or updates in updatable views. ANSI SQL 92 defines two check option
      #   values: CASCADED and LOCAL. See your database documentation for allowed values.
      # [<tt>:primary_key</tt>]
      #   If present, create a primary key for the view using this value
      def create_or_replace_view(name, select_query, options={})
        if supports_views? && replaces_views?
          view_definition = ViewDefinition.new(self, select_query)
          
          if block_given?
            yield view_definition
          end

          create_sql = "CREATE OR REPLACE VIEW "
          create_sql << "#{quote_table_name(name)} "
          if supports_view_columns_definition? && !view_definition.to_sql.blank?
            create_sql << "("
            create_sql << view_definition.to_sql
            create_sql << ") " 
          end
          create_sql << "AS #{view_definition.select_query}"
          create_sql << " WITH #{options[:check_option]} CHECK OPTION" if options[:check_option]
          execute create_sql
        end

        if options[:primary_key]
          create_primary_key_for_view name, options[:primary_key]
        end
      end

      def create_primary_key_for_view(name, primary_key)
        create_primary_key(name, primary_key, 'VIEW')
      end
      
      def create_primary_key_for_mv(name, primary_key)
        create_primary_key(name, primary_key, 'MATERIALIZED VIEW')
      end
      
      def create_primary_key(name, primary_key, type)
        sql = "ALTER #{type} #{quote_table_name(name)} ADD CONSTRAINT #{quote_table_name(name + "_pk")} PRIMARY KEY(#{primary_key}) DISABLE"
        execute sql
      end

      # Schedule a job to refresh given materialized view. 
      # Refresh schedule string must follow oracle repeat_interval syntax:
      # http://www.oracle-base.com/articles/10g/scheduler-10g.php#configuring_the_scheduler
      def create_mv_refresh_job(name, refresh_schedule)
        schema = current_schema
        job_action = %Q[BEGIN
          DBMS_MVIEW.REFRESH ('#{schema}.#{name.upcase}', 'C');
          EXCEPTION
          WHEN OTHERS THEN
            mail.send_mail(
               from_s => '#{schema}',
               to_r => 'SOMPROG@LISTS.UPENN.EDU',
               subject => 'MV refreshing failed',
               message => SQLCODE || SUBSTR(SQLERRM, 1, 100));
          END;]
      
        job = %Q[BEGIN DBMS_SCHEDULER.CREATE_JOB (
                    job_name => '#{schema}.#{name.upcase}_refresh',
                    job_type => 'plsql_block',
                    job_action => q'[#{job_action}]', 
                    repeat_interval => '#{refresh_schedule}',
                    enabled => true,
                    auto_drop => false,
                    comments => 'Refresh #{schema}.#{name.upcase} against source.'
                    );
                  END;]      
                  
        execute job
      end

      # Also creates a view, with the specific purpose of remapping column names
      # to make non-ActiveRecord tables friendly with the naming
      # conventions, while maintaining legacy app compatibility.
      def create_mapping_view(old_name, new_name, options = {})
        return unless supports_views?
        
        col_names = columns(old_name).collect { |col| col.name.to_sym }
        mapper = MappingDefinition.new(col_names)
        
        yield mapper
        
        if options[:force]
          drop_view(new_name) rescue nil
        end

        view_sql = "CREATE VIEW #{new_name} "
        if supports_view_columns_definition?
          view_sql << "(#{mapper.view_cols.collect { |c| quote_column_name(c) }.join(', ')}) "
        end
        view_sql << "AS SELECT #{mapper.select_cols.collect { |c| quote_column_name(c) }.join(', ')} FROM #{old_name}"
        execute view_sql
      end
      
      # Drop a materialized view
      def drop_materialized_view(name)
        return unless supports_materialized_views?

        drop_mv_refresh_job(name)
        execute "DROP MATERIALIZED VIEW #{quote_table_name(name)}"
      end
      
      # Drops a scheduled job. Catches job does not exist exception as it is run when dropping
      # a materialized view, which may not have a scheduled job.
      def drop_mv_refresh_job(name)
        schema = current_schema
        begin
          execute "BEGIN DBMS_SCHEDULER.DROP_JOB ('#{schema}.#{name.upcase}_refresh'); END;"
        rescue => exception
          case exception.to_s
          when /ORA-27475/ # Job does not exist
            return true
          else
            raise
          end
        end
      end

      # Drop a view.
      # The +options+ hash can include the following keys:
      # [<tt>:drop_behavior</tt>]
      #   Specify the drop behavior. ANSI SQL 92 defines two drop behaviors, CASCADE and RESTRICT. See your
      #   database documentation to determine what drop behaviors are available.
      def drop_view(name, options={})
        if supports_views?
          drop_sql = "DROP VIEW #{quote_table_name(name)}"
          drop_sql << " #{options[:drop_behavior]}" if options[:drop_behavior]
          execute drop_sql
        end
      end
    end
  end
end
