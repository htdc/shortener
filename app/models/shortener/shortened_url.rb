class Shortener::ShortenedUrl < ActiveRecord::Base

  REGEX_LINK_HAS_PROTOCOL = Regexp.new('\Ahttp:\/\/|\Ahttps:\/\/', Regexp::IGNORECASE)

  validates :url, presence: true

  around_create :set_unique_key_with_retries!

  # allows the shortened link to be associated with a user
  belongs_to :owner, polymorphic: true, optional: true

  # exclude records in which expiration time is set and expiration time is greater than current time
  scope :unexpired, -> { where(arel_table[:expires_at].eq(nil).or(arel_table[:expires_at].gt(::Time.current.to_s(:db)))) }

  # ensure the url starts with it protocol and is normalized
  def self.clean_url(url)

    url = url.to_s.strip
    if url !~ REGEX_LINK_HAS_PROTOCOL && url[0] != '/'
      url = "/#{url}"
    end
    URI.parse(url).normalize.to_s
  end

  # Makes short urls without saving them yet.
  def self.generate_without_save(destination_url, owner: nil)
    scope = owner ? owner.shortened_urls : self
    result = scope.where(url: clean_url(destination_url)).build(expires_at: nil)

    count = 0
    loop do
      count += 1
      raise "We never found a unique key... Why? #{result.unique_key} not unique" if count == 7
      result.unique_key = Shortener::ShortenedUrl.new.send(:generate_unique_key)
      break unless Shortener::ShortenedUrl.exists?(unique_key: result.unique_key)
    end
  end

  # generate a shortened link from a url
  # link to a user if one specified
  # throw an exception if anything goes wrong
  def self.generate!(destination_url, owner: nil, custom_key: nil, expires_at: nil, fresh: false)
    # if we get a shortened_url object with a different owner, generate
    # new one for the new owner. Otherwise return same object
    if destination_url.is_a? Shortener::ShortenedUrl
      if destination_url.owner == owner
        result = destination_url
      else
        result = generate!(destination_url.url,
                            owner:      owner,
                            custom_key: custom_key,
                            expires_at: expires_at,
                            fresh:      fresh
                          )
      end
    else
      scope = owner ? owner.shortened_urls : self

      if fresh
        result = scope.where(url: clean_url(destination_url)).create(unique_key: custom_key, expires_at: expires_at)
      else
        result = scope.where(url: clean_url(destination_url)).first_or_create(unique_key: custom_key, expires_at: expires_at)
      end
    end

    result
  end

  # return shortened url on success, nil on failure
  def self.generate(destination_url, owner: nil, custom_key: nil, expires_at: nil, fresh: false)
    begin
      generate!(destination_url, owner: owner, custom_key: custom_key, expires_at: expires_at, fresh: fresh)
    rescue => e
      logger.info e
      nil
    end
  end

  private

  # we'll rely on the DB to make sure the unique key is really unique.
  # if it isn't unique, the unique index will catch this and raise an error
  def set_unique_key_with_retries!
    # Don't retry if we've picked a unique key, as we expect to get that key.
    retries = unique_key.blank? ? 5 : 0

    begin
      self.unique_key = generate_unique_key if unique_key.blank?
    end
      yield # As in continue to 'create', as this is called from around_create
    rescue ActiveRecord::RecordNotUnique
      if retries <= 0
        logger.info("too many retries, giving up")
        raise
      else
        logger.info("retrying with different unique key")
        retries -= 1
        self.unique_key = nil
        retry
      end
  end

  def generate_unique_key
    charset = ::Shortener.key_chars
    key = nil
    forbidden_keys_as_regex = Shortener.forbidden_keys.blank? ? nil : /#{::Shortener.forbidden_keys.join("|")}/i
    until key && (key =~ forbidden_keys_as_regex).nil?
      key = (0...::Shortener.unique_key_length).map{ charset[rand(charset.size)] }.join
    end
    key
  end

end
