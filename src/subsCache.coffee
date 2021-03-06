# debug = (args...) -> console.log.apply(console, args)
debug = (args...) -> return

class @SubsCache
  @caches: []
  
  constructor: (obj) ->
    expireAfter = undefined
    cacheLimit = undefined
    if obj
      {expireAfter, cacheLimit} = obj
      
    # defaults
    if expireAfter is undefined
      expireAfter = 5
    if cacheLimit is undefined
      cacheLimit = 10
    # catch an odd error
    if cacheLimit is 0
      console.warn "cacheLimit cannot be zero!"
      cacheLimit = 1

    # initialize instance variables
    @expireAfter = expireAfter
    @cacheLimit = cacheLimit
    @cache = {}
    @allReady = new ReactiveVar(true)
    SubsCache.caches.push(@)

  ready: ->
    @allReady.get()

  onReady: (callback) ->
    Tracker.autorun (c) =>
      if @ready()
        c.stop()
        callback()

  @clearAll: ->
    @caches.map (s) -> s.clear()

  clear: ->
    _.values(@cache).map((sub)-> sub.stopNow())

  subscribe: (args...) ->
    args.unshift(@expireAfter)
    @subscribeFor.apply(this, args)

  subscribeFor: (expireTime, args...) ->
    if Meteor.isServer
      # If we're using fast-render for SSR
      Meteor.subscribe.apply(Meteor.args)
    else
      hash = EJSON.stringify(args)
      cache = @cache
      if hash of cache
        # if we find this subscription in the cache, then restart it
        cache[hash].restart()
      else
        # make sure the subscription won't be stopped if we are in a reactive computation
        sub = Tracker.nonreactive -> Meteor.subscribe.apply(Meteor, args)
        # create an object to represent this subscription in the cache
        cachedSub =
          sub: sub
          hash: hash
          compsCount: 0
          timerId: null
          expireTime: expireTime
          when: null
          ready: -> 
            @sub.ready()
          onReady: (callback)->
            if @ready() 
              Tracker.nonreactive -> callback()
            else
              Tracker.autorun (c) =>
                if @ready()
                  c.stop()
                  Tracker.nonreactive -> callback()
          start: ->
            # so we know what to throw out when the cache overflows
            @when = Date.now() 
            # we need to count the number of computations that have called
            # this subscription so that we don't release it too early
            @compsCount += 1
            # if the computation stops, then delayedStop
            c = Tracker.currentComputation
            c?.onInvalidate => 
              @delayedStop()
          stop: -> @delayedStop()
          delayedStop: ->
            if expireTime >= 0
              @timerId = Meteor.setTimeout(@stopNow.bind(this), expireTime*1000*60)
          restart: ->
            # if we'are restarting, then stop the timer
            Meteor.clearTimeout(@timerId)
            @start()
          stopNow: ->
            @compsCount -= 1
            if @compsCount <= 0
              @sub.stop()
              delete cache[@hash]

        # delete the oldest subscription if the cache has overflown
        if @cacheLimit > 0
          allSubs = _.sortBy(_.values(cache), (x) -> x.when)
          numSubs = allSubs.length
          if numSubs >= @cacheLimit
            needToDelete = numSubs - @cacheLimit + 1
            for i in [0...needToDelete]
              debug "overflow", allSubs[i]
              allSubs[i].stopNow()



        cache[hash] = cachedSub
        cachedSub.start()

        # reactively set the allReady reactive variable
        @allReadyComp?.stop() 
        Tracker.autorun (c) =>
          @allReadyComp = c
          subs = _.values(@cache)
          if subs.length > 0
            @allReady.set subs.map((x) -> x.ready()).reduce((a,b) -> a and b)

      return cache[hash]