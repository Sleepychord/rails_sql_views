module RailsSqlViews
  module Migration
    module CommandRecorder
        def create_view(*args)
          record(:create_view, args)
        end   

        def create_materialized_view(*args)
          record(:create_materialized_view, args)
        end   

        def invert_create_view(args)
          [:drop_view, args[0]]
        end 

        def invert_create_materialized_view(args)
          [:drop_materialized_view, args[0]]
        end 
    end
  end
end
