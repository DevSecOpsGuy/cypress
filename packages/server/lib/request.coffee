_          = require("lodash")
r          = require("request")
rp         = require("request-promise")
url        = require("url")
tough      = require("tough-cookie")
debug      = require("debug")("cypress:server:request")
moment     = require("moment")
Promise    = require("bluebird")
stream     = require("stream")
agent      = require("@packages/network").agent
statusCode = require("./util/status_code")
Cookies    = require("./automation/cookies")

Cookie    = tough.Cookie
CookieJar = tough.CookieJar

## shallow clone the original
serializableProperties = Cookie.serializableProperties.slice(0)

process.env.NODE_TLS_REJECT_UNAUTHORIZED = "0"

getOriginalHeaders = (req = {}) ->
  ## the request instance holds an instance
  ## of the original ClientRequest
  ## as the 'req' property which holds the
  ## original headers
  req.req?.headers ? req.headers

isRetriableError = (err) ->
  ['ECONNREFUSED', 'ECONNRESET', 'EPIPE'].includes(err.code)

pick = (resp = {}) ->
  req = resp.request ? {}

  headers = getOriginalHeaders(req)

  {
    "Request Body":     req.body ? null
    "Request Headers":  headers
    "Request URL":      req.href
    "Response Body":    resp.body ? null
    "Response Headers": resp.headers
    "Response Status":  resp.statusCode
  }

setCookies = (cookies, jar, headers, url) =>
  return if _.isEmpty(cookies)

  if jar
    cookies.forEach (c) ->
      jar.setCookie(c, url, {ignoreError: true})

  else
    headers.Cookie = createCookieString(cookies)

newCookieJar = ->
  j = new CookieJar(undefined, {looseMode: true})

  ## match the same api signature as @request
  {
    _jar: j

    toJSON: ->
      ## temporarily include the URL property
      ## and restore afterwards. this is used to fix
      ## https://github.com/cypress-io/cypress/issues/1321
      Cookie.serializableProperties = serializableProperties.concat("url")
      cookies = j.toJSON()
      Cookie.serializableProperties = serializableProperties
      return cookies

    setCookie: (cookieOrStr, uri, options) ->
      ## store the original URL this cookie was set on
      if cookie = j.setCookieSync(cookieOrStr, uri, options)
        ## only set cookie URL if it was created correctly
        ## since servers may send invalid cookies that fail
        ## to parse - we may get undefined here
        cookie.url = uri

      return cookie

    getCookieString: (uri) ->
      j.getCookieStringSync(uri, {expire: false})

    getCookies: (uri) ->
      j.getCookiesSync(uri, {expire: false})
  }

convertToJarCookie = (cookies = []) ->
  _.map cookies, (cookie) ->
    props = {
      key:      cookie.name
      path:     cookie.path
      value:    cookie.value
      secure:   cookie.secure
      httpOnly: cookie.httpOnly
      hostOnly: cookie.hostOnly
    }

    ## hostOnly is the default when
    ## NO DOMAIN= attribute was set
    ##
    ## so if we are not hostOnly then
    ## this cookie WAS created with
    ## a Domain= attribute and therefore
    ## which lessens whichs domains this
    ## cookie may be sent, and therefore
    ## we need to set props.domain else
    ## the domain would be implied by URL
    if not cookie.hostOnly
      ## https://github.com/salesforce/tough-cookie/issues/26
      ## we need to strip the leading dot
      ## on domains else tough cookie will not
      ## properly send these cookies.
      ## we get dot leading domains from the
      ## chrome cookie API's
      props.domain = _.trimStart(cookie.domain, ".")

    ## if we have an expiry then this
    ## is the number of seconds since the epoch
    ## that this cookie expires. we need to convert
    ## this to a JS date object
    if cookie.expiry?
      props.expires = moment.unix(cookie.expiry).toDate()

    return new Cookie(props)

reduceCookieToArray = (c) ->
  _.reduce c, (memo, val, key) ->
    memo.push [key.trim(), val.trim()].join("=")
    memo
  , []

createCookieString = (c) ->
  reduceCookieToArray(c).join("; ")

module.exports = (options = {}) ->
  defaults = {
    timeout: options.timeout ? 20000
    agent: agent
    ## send keep-alive with requests since Chrome won't send it in proxy mode
    ## https://github.com/cypress-io/cypress/pull/3531#issuecomment-476269041
    headers: {
      "Connection": "keep-alive"
    }
    proxy: null ## upstream proxying is handled by CombinedAgent
  }

  r  = r.defaults(defaults)
  rp = rp.defaults(defaults)

  return {
    r: require("request")

    rp: require("request-promise")

    reduceCookieToArray: reduceCookieToArray

    createCookieString: createCookieString

    create: (strOrOpts, promise) ->
      switch
        when _.isString(strOrOpts)
          opts = {
            url: strOrOpts
          }
        else
          opts = strOrOpts

      if promise
        rp(opts)
      else
        r(opts)

    contentTypeIsJson: (response) ->
      ## TODO: use https://github.com/jshttp/type-is for this
      response?.headers?["content-type"]?.includes("application/json")

    parseJsonBody: (body) ->
      try
        JSON.parse(body)
      catch e
        body

    normalizeResponse: (push, response) ->
      req = response.request ? {}

      push(response)

      response = _.pick(response, "statusCode", "body", "headers")

      ## normalize status
      response.status = response.statusCode
      delete response.statusCode

      _.extend(response, {
        ## normalize what is an ok status code
        statusText:     statusCode.getText(response.status)
        isOkStatusCode: statusCode.isOk(response.status)
        requestHeaders: getOriginalHeaders(req)
        requestBody:    req.body
      })

      ## if body is a string and content type is json
      ## try to convert the body to JSON
      if _.isString(response.body) and @contentTypeIsJson(response)
        response.body = @parseJsonBody(response.body)

      return response

    setJarCookies: (jar, automationFn) ->
      setCookie = (cookie) ->
        cookie.name = cookie.key

        ## TODO: fix this
        return if cookie.name and cookie.name.startsWith("__cypress")

        ## tough-cookie will return us a cookie that looks like this....
        # { key: 'secret-session',
        #   value: 's%3AxMYoMAXnnMN2pzjYKJx21Id9zjQOaPsT.aKJv1mlfNlCEtrPUjgt48KX0c7xNiB%2Bb0fLijmi48dY',
        #   domain: 'session.foobar.com',
        #   path: '/',
        #   httpOnly: true,
        #   extensions: [ 'SameSite=Strict' ],
        #   hostOnly: true,
        #   creation: '2016-09-04T18:48:06.882Z',
        #   lastAccessed: '2016-09-04T18:48:06.882Z',
        #   name: 'secret-session' }
        #
        # { key: '2293-session',
        #   value: 'true',
        #   domain: 'localhost',
        #   path: '/',
        #   hostOnly: true,
        #   creation: '2016-09-05T03:03:20.780Z',
        #   lastAccessed: '2016-09-05T03:03:20.780Z',
        #   name: '2293-session' }

        switch
          when cookie.maxAge?
            ## when we have maxAge
            ## prefer that
            ## unix returns us time in seconds
            ## from the epoc + we add that
            ## to maxAge since thats relative seconds
            ## from now
            cookie.expiry = moment().unix() + cookie.maxAge
          when ex = cookie.expires
            ## tough cookie provides javascript date
            ## formatted expires
            cookie.expiry = moment(ex).unix()

        automationFn("set:cookie", cookie)
        .then ->
          ## the automation may return us null in
          ## the case an expired cookie is removed
          Cookies.normalizeCookieProps(cookie)

      Promise.try ->
        store = jar.toJSON()

        debug("setting request jar cookies %o", store.cookies)

        ## this likely needs
        ## to be an 'each' not a map
        ## since we need to set cookies
        ## in sequence and not all at once
        ## because cookies could have colliding
        ## values which need to be set in order
        Promise.each(store.cookies, setCookie)

    sendStream: (headers, automationFn, options = {}, cb) ->
      _.defaults options, {
        headers: {}
        jar: true
        retry: false
      }

      if ua = headers["user-agent"]
        options.headers["user-agent"] = ua

      ## create a new jar instance
      ## unless its falsy or already set
      if options.jar is true
        options.jar = newCookieJar()

      _.extend options, {
        strictSSL: false
      }

      self = @

      if jar = options.jar
        followRedirect = options.followRedirect

        options.followRedirect = (incomingRes) ->
          ## if we have a cookie jar
          req = @

          newUrl = url.resolve(options.url, incomingRes.headers.location)

          ## and when we know we should follow the redirect
          ## we need to override the init method and
          ## first set the existing jar cookies on the browser
          ## and then grab the cookies for the new url
          req.init = _.wrap req.init, (orig, opts) =>
            self.setJarCookies(jar, automationFn)
            .then ->
              automationFn("get:cookies", {url: newUrl, includeHostOnly: true})
            .then(convertToJarCookie)
            .then (cookies) ->
              setCookies(cookies, jar, null, newUrl)
            .then ->
              orig.call(req, opts)

          followRedirect.call(req, incomingRes)

      createAndRetry = (iteration = 0) =>
        newReq = @create(options)
        newReq.getJar = -> options.jar

        onError = (err) ->
          debug("caught request error in sendstream #{err.code} #{err} %o", err)

          newReq.on "error", (newErr) ->
            # sockets can/do emit multiple errors depending on how they're closed
            # listen for these extra errors so that the whole process doesn't crash
            debug("received error on already-errored request stream: %o", {
              originalError: err,
              lastError: newErr
            })

          if not isRetriableError(err)
            return cb(err)

          if iteration >= 2
            debug("retried 3x and still network error, not retrying")
            return cb(err)

          debug("retry %o", {
            iteration
            delay: options.timeout
          })

          setTimeout ->
            createAndRetry(iteration + 1)
          , options.timeout || 0

        newReq
        .once "error", onError
        .once "response", (incomingRes) ->
          debug('received response event')
          newReq.removeListener("error", onError)
          cb(null, newReq, incomingRes)

      send = ->
        debug("sending request as stream %o", _.omit(options, "jar"))

        createAndRetry()

      automationFn("get:cookies", {url: options.url, includeHostOnly: true})
      .then(convertToJarCookie)
      .then (cookies) ->
        setCookies(cookies, options.jar, options.headers, options.url)
      .then(send)

    send: (headers, automationFn, options = {}) ->
      _.defaults options, {
        headers: {}
        gzip: true
        jar: true
        cookies: true
        followRedirect: true
      }

      if ua = headers["user-agent"]
        options.headers["user-agent"] = ua

      ## normalize case sensitivity
      ## to be lowercase
      if a = options.headers.Accept
        delete options.headers.Accept
        options.headers.accept = a

      ## https://github.com/cypress-io/cypress/issues/338
      _.defaults(options.headers, {
        accept: "*/*"
      })

      ## create a new jar instance
      ## unless its falsy or already set
      if options.jar is true
        options.jar = newCookieJar()

      _.extend(options, {
        strictSSL: false
        simple: false
        resolveWithFullResponse: true
      })

      ## https://github.com/cypress-io/cypress/issues/322
      ## either turn these both on or off
      options.followAllRedirects = options.followRedirect

      if options.form is true
        ## reset form to whatever body is
        ## and nuke body
        options.form = options.body
        delete options.json
        delete options.body

      send = =>
        ms = Date.now()

        self             = @
        redirects        = []
        requestResponses = []

        push = (response) ->
          requestResponses.push(pick(response))

        if options.followRedirect
          options.followRedirect = (incomingRes) ->
            newUrl = url.resolve(options.url, incomingRes.headers.location)

            ## normalize the url
            redirects.push([incomingRes.statusCode, newUrl].join(": "))

            push(incomingRes)

            ## if we have a cookie jar
            if jar = options.jar
              req = @

              ## and when we know we should follow the redirect
              ## we need to override the init method and
              ## first set the existing jar cookies on the browser
              ## and then grab the cookies for the new url
              req.init = _.wrap req.init, (orig, opts) =>
                self.setJarCookies(options.jar, automationFn)
                .then ->
                  automationFn("get:cookies", {url: newUrl, includeHostOnly: true})
                .then(convertToJarCookie)
                .then (cookies) ->
                  setCookies(cookies, jar, null, newUrl)
                .then ->
                  orig.call(req, opts)

            ## cause the redirect to happen
            ## but swallow up the incomingRes
            ## so we can build an array of responses
            return true

        createAndRetry = (iteration = 0, originalErr = null) ->
          @create(options, true)
          .catch(err) ->
            if not isRetriableError(err)
              throw err

            debug("caught request error in send #{err.code} #{err}")

            originalErr ?= err

            if iteration >= 3
              debug("retried 3x and still network error, not retrying")
              throw originalErr

            Promise.delay(options.timeout)
            .then ->
              createAndRetry(iteration + 1, originalErr)

        createAndRetry()
        .then(@normalizeResponse.bind(@, push))
        .then (resp) =>
          ## TODO: move duration somewhere...?
          ## does node store this somewhere?
          ## we could probably calculate this ourselves
          ## by using the date headers
          resp.duration            = Date.now() - ms
          resp.allRequestResponses = requestResponses

          if redirects.length
            resp.redirects = redirects

          if options.followRedirect is false and (loc = resp.headers.location)
            ## resolve the new location head against
            ## the current url
            resp.redirectedToUrl = url.resolve(options.url, loc)

          if options.jar
            @setJarCookies(options.jar, automationFn)
            .return(resp)
          else
            resp

      if c = options.cookies
        ## if we have a cookie object then just
        ## send the request up!
        if _.isObject(c)
          setCookies(c, null, options.headers)
          send()
        else
          ## else go get the cookies first
          ## then make the request

          ## TODO: we can simply use the 'url' property on the cookies API
          ## which automatically pulls all of the cookies that would be
          ## set for that url!
          automationFn("get:cookies", {url: options.url, includeHostOnly: true})
          .then(convertToJarCookie)
          .then (cookies) ->
            setCookies(cookies, options.jar, options.headers, options.url)
          .then(send)
      else
        send()

  }
