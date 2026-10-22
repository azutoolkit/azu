module Azu
  # One page of results plus the numbers a UI needs.
  #
  # ```
  # page = User.active.recent.paginate(page: 2, per_page: 20)
  # page.records     # => Array(User)
  # page.total       # => total rows matching the query
  # page.total_pages # => ceil(total / per_page)
  # ```
  struct Page(T)
    include Enumerable(T)

    getter records : Array(T)
    getter total : Int64
    getter page : Int32
    getter per_page : Int32

    def initialize(@records : Array(T), @total : Int64, @page : Int32, @per_page : Int32)
    end

    def each(& : T ->)
      @records.each { |record| yield record }
    end

    def total_pages : Int32
      ((@total + @per_page - 1) // @per_page).to_i32
    end

    def next_page : Int32?
      @page < total_pages ? @page + 1 : nil
    end

    def prev_page : Int32?
      @page > 1 ? @page - 1 : nil
    end

    def first_page? : Bool
      @page <= 1
    end

    def last_page? : Bool
      @page >= total_pages
    end

    def empty? : Bool
      @records.empty?
    end

    def to_a : Array(T)
      @records
    end

    # `{page:, per_page:, total:, total_pages:, next_page:, prev_page:}` for JSON APIs.
    def meta : NamedTuple(page: Int32, per_page: Int32, total: Int64, total_pages: Int32, next_page: Int32?, prev_page: Int32?)
      {page: @page, per_page: @per_page, total: @total, total_pages: total_pages, next_page: next_page, prev_page: prev_page}
    end
  end
end

module CQL::ActiveRecord::Queryable
  class QueryBuilder(T)
    MAX_PER_PAGE = 1_000

    # Runs the query; same as `all`, so chains read naturally: `User.active.recent.to_a`.
    def to_a : Array(T)
      all
    end

    # `order_by(created_at: :desc)` / `order_by(:name)` (alias of `order`).
    def order_by(**fields)
      order(**fields)
    end

    def order_by(*fields : Symbol | String)
      order(*fields)
    end

    # Counts the matching rows, then loads one page (preloads included).
    #
    # `per_page` is clamped to 1..1000 and `page` to 1.. so user input is safe to pass through.
    def paginate(page : Int32 = 1, per_page : Int32 = 20) : Azu::Page(T)
      page = {page, 1}.max
      per_page = per_page.clamp(1, MAX_PER_PAGE)
      # Postgres rejects ORDER BY on a bare aggregate, so count on an unordered clone.
      counting = clone_builder
      counting.@query.order_by.clear
      total = counting.count.to_i64
      records = limit(per_page).offset((page - 1) * per_page).all
      Azu::Page(T).new(records, total, page, per_page)
    end
  end
end
