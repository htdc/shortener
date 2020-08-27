class Shortener::ShortenedUrlsController < ActionController::Base

  # find the real link for the shortened link key and redirect
  def show
    # only use the leading valid characters
    token = /^([#{Shortener.key_chars.join}]*).*/.match(params[:id])[1]

    # pull the link out of the db
    sl = ::Shortener::ShortenedUrl.unexpired.where(unique_key: token).first

    if sl
      # don't want to wait for the increment to happen, make it snappy!
      # this is the place to enhance the metrics captured
      # for the system. You could log the request origin
      # browser type, ip address etc.
      sl.increment!(:use_count)

      filtered_params = params.permit!.to_h.except *[:id, :action, :controller]
      url = sl.url

      if filtered_params.present?
        uri = URI.parse(sl.url)
        existing_params = Rack::Utils.parse_nested_query(uri.query)
        merged_params   = existing_params.merge(filtered_params)
        uri.query       = merged_params.to_query
        url             = uri.to_s
      end

      # do a 301 redirect to the destination url
      redirect_to url, status: :moved_permanently
    else
      # if we don't find the shortened link, redirect to the root
      # make this configurable in future versions
      redirect_to Shortener.default_redirect
    end
  end

end
