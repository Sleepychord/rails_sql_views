module RailsSqlViews
  module ConnectionAdapters
    module OracleEnhancedAdapter
      def supports_materialized_views?
        true
      end

      # Returns true as this adapter supports views.
      def supports_views?
        true
      end
      
      def base_tables(name = nil) #:nodoc:
        tables = []
        cursor = execute("SELECT TABLE_NAME FROM ALL_TABLES WHERE owner = SYS_CONTEXT('userenv', 'current_schema') AND secondary = 'N'", name)
        while row = cursor.fetch
          tables << row[0]
        end
        tables
      end
      alias nonview_tables base_tables
      
      def views(name = nil) #:nodoc:
        views = []
        cursor = execute("SELECT VIEW_NAME FROM ALL_VIEWS WHERE owner = SYS_CONTEXT('userenv', 'current_schema')", name)
        while row = cursor.fetch
          views << row[0]
        end
        views
      end
      
      # Get the view select statement for the specified table.
      def view_select_statement(view, name=nil)
        cursor = execute("SELECT TEXT FROM ALL_VIEWS WHERE VIEW_NAME = '#{view}' AND owner = SYS_CONTEXT('userenv', 'current_schema')", name)
        if row = cursor.fetch
          return row[0]
        else
          raise "No view called #{view} found"
        end
      end
    end
  end
end
