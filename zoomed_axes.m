classdef zoomed_axes < handle
    
    % Public properties
    properties
        Axes matlab.graphics.axis.Axes
        ParentAxes matlab.graphics.axis.Axes
        Box matlab.graphics.primitive.Patch
        BoxConnectors matlab.graphics.primitive.Patch = matlab.graphics.primitive.Patch.empty
    end 

    properties (SetObservable)
        ZoomRegion (1,:) double
    end
    
    % read-only properties
    properties (SetAccess = private)
        ParentFigure matlab.ui.Figure
        Type char = 'zoomed_axes'
    end
        
    % Private properties
    properties (Access = private)
        Listeners event.listener = event.listener.empty
        ZoomAxesCollision double = 0
        ZoomBoxCollision  double = 0
        StartingPos   double
        StartingAxesPos double
        StartingBoxVertices  double
        DragIndices   double
        PauseBoxUpdate logical = false
        ParentFigureOriginalUnits char
    end
    
    methods
        
        function obj = zoomed_axes(parentAxes, zoomRegion)
            
            arguments
                parentAxes (1,1) matlab.graphics.axis.Axes;
                zoomRegion (4,1) double;
            end
            
            % get containing figure
            obj.ParentFigure = ancestor(parentAxes,'figure');        
            
            % Create parent axes pointer and add zoom region
            obj.ParentAxes = parentAxes;
            obj.ZoomRegion = zoomRegion;
                     
            % create new axes
            newPos = [parentAxes.Position(1) + parentAxes.Position(3)/2, parentAxes.Position(2) + parentAxes.Position(4)/2, ...
                      parentAxes.Position(3)/3, parentAxes.Position(4)/3];
                  
            obj.Axes = axes(parentAxes.Parent, 'Position', newPos);
            obj.Axes.Box = 'on';
            
            % copy over the whole data set to new axes(because I'm lazy)
            % do this before drawing box so that we don't copy the box over
            obj.refresh_data()
            
            % create listeners to update line objects
            lines = findobj(obj.ParentAxes,'Type','Line');
            props = {'XData', 'YData', 'Color', 'LineWidth', 'LineStyle', 'Marker', 'MarkerSize'};
            for k = 1:numel(lines)
                for i = 1:length(props)
                    obj.Listeners(end+1) = addlistener(lines(k), props{i}, 'PostSet', @(~,~) obj.refresh_data());
                end
            end

            hold(parentAxes, 'on');
            
            % create zoom box on parent axes
            obj.Box = patch(zoomRegion([1 3 3 1 1]), zoomRegion([2 2 4 4 2]), [0 0 0], 'facealpha', 0, 'parent', parentAxes, 'tag', 'zoombox');
            obj.Box.EdgeColor = [1 1 1]*0.4;
            obj.Box.EdgeAlpha = 0.4;
            obj.Box.LineWidth = 1;
            
            % Create box connectors
            % get coordinates of zoom axes bounds on the parent axis
            coords = obj.get_zoom_axes_coordinates();
            
            % start bottom left, go CCW
          
            xinds = [1 3 3 1];
            yinds = [2 2 4 4];
            for i = 1:4
                xdata = [obj.Box.XData(i); coords(xinds(i))];
                ydata = [obj.Box.YData(i); coords(yinds(i))];
                obj.BoxConnectors(end+1) = patch(xdata, ydata, 'k', 'parent', parentAxes, 'facealpha', 0, 'tag', 'zoomboxconnector');
                obj.BoxConnectors(end).EdgeColor = obj.Box.EdgeColor;
            end
            
            hold(parentAxes, 'off');
            set(obj.BoxConnectors, 'EdgeColor', [1 1 1]*0.4);
            set(obj.BoxConnectors, 'EdgeAlpha', 0.4);
            set(obj.BoxConnectors, 'LineWidth', 0.4)

            % Set axis limits based on the zoom region
            obj.Axes.XLim = zoomRegion([1,3]);
            obj.Axes.YLim = zoomRegion([2,4]);
            
            % Create listeners to match box location to zoom axes panning
            obj.Listeners(end+1) = addlistener(obj.Axes, 'XLim', 'PostSet', @(~,~) obj.update_box_from_axes());
            obj.Listeners(end+1) = addlistener(obj.Axes, 'YLim', 'PostSet', @(~,~) obj.update_box_from_axes());
            obj.Listeners(end+1) = addlistener(obj.ParentAxes, 'XLim', 'PostSet', @(~,~) obj.update_box_from_axes());
            obj.Listeners(end+1) = addlistener(obj.ParentAxes, 'YLim', 'PostSet', @(~,~) obj.update_box_from_axes());
            
            % For newer versions of matlab, we also need to set the "LimitsChangedFunction"
            % only available in 2021a and later. pre-2025a this will work like a listener and update as panning is completed
            % 2025a and later it is only called after panning is complete, so we still need to keep the above listeners
            obj.Axes.XAxis.LimitsChangedFcn = @(~,~) obj.update_box_from_axes();
            obj.Axes.YAxis.LimitsChangedFcn = @(~,~) obj.update_box_from_axes();
            obj.ParentAxes.XAxis.LimitsChangedFcn = @(~,~) obj.update_box_from_axes();
            obj.ParentAxes.YAxis.LimitsChangedFcn = @(~,~) obj.update_box_from_axes();
            
            % add object to figure list of zoomed axes
            list = getappdata(obj.ParentFigure, 'ZoomedAxesList');
            if isempty(list)
                list = zoomed_axes.empty;
                % install global callback only once
                obj.ParentFigure.WindowButtonDownFcn = @(src,evt)zoomed_axes.globalButtonDownFcn(src,evt);
                obj.ParentFigure.WindowButtonUpFcn   = @(src,evt)zoomed_axes.globalButtonDownFcn(src,evt);                
            end
            
            list(end+1) = obj;
            setappdata(obj.ParentFigure, 'ZoomedAxesList', list);

            % attach mouse callbacks
            % obj.ParentFigure.WindowButtonDownFcn = @(src,evt)obj.startDrag();
            obj.ParentFigure.WindowButtonUpFcn   = @(src,evt)obj.stopDrag();
            
            % Add listener to update box connectors
            % Create listeners to match box location to zoom axes panning
            obj.Listeners(end+1) = addlistener(obj.Axes, 'Position', 'PostSet', @(~,~) obj.update_box_connectors());

            % Add listener to udpate box from ZoomRegion
            obj.Listeners(end+1) = addlistener(obj, 'ZoomRegion', 'PostSet', @(~,~) obj.update_box_from_zoom_region());
            
        end
        
        function check_zoom_axes_collision(obj, buffer)
                       
            cp = obj.ParentFigure.CurrentPoint;  % in pixels
            axPix = getpixelposition(obj.Axes,false);
            
            % simple hit test: inside axes? near border?
            mouseX = cp(1);
            mouseY = cp(2);
            
            % check for clicking on zoomed axes 
            % -------------------------------------------------------------
           
            % Get the actual coordinates in pixels
            xc = [axPix(1), axPix(1)+axPix(3), axPix(1)+axPix(3), axPix(1)];
            yc = [axPix(2), axPix(2), axPix(2)+axPix(4), axPix(2)+axPix(4)];

            % check corner collision
            corner_dist = sqrt((xc-mouseX).^2 + (yc-mouseY).^2);
            
            % default to no collision
            obj.ZoomAxesCollision = 0;
            obj.DragIndices = [];
            
            % If on corner, flag as ZoomAxesCollision as true
            if any(corner_dist <= buffer)
                
                obj.ZoomAxesCollision = 1;
                
                % set which node we were near
                [~, obj.DragIndices] = min(corner_dist);
                
                obj.StartingAxesPos = obj.Axes.Position;
                obj.StartingPos = [mouseX, mouseY];
                
            % if not on corner, check if we are inside zoom axes  
            elseif (mouseX > xc(1) && mouseX < xc(3) && mouseY>yc(1) && mouseY<yc(3))
                
                % Set to type 2
                obj.ZoomAxesCollision = 2;
                
                obj.StartingAxesPos = obj.Axes.Position;
                obj.StartingPos = [mouseX, mouseY];
                
                % Set to dragging all
                obj.DragIndices = [1,2,3,4];
                
            end
                
        end
        
        function check_zoom_box_collision(obj, buffer)
            
            % current point on parent axes
            cp = obj.ParentAxes.CurrentPoint;
            
            % distance to nearest box corner
            dx = (cp(1,1) - obj.Box.Vertices(:,1))./(obj.Box.Vertices(3,1) - obj.Box.Vertices(1,1));
            dy = (cp(1,2) - obj.Box.Vertices(:,2))./(obj.Box.Vertices(3,2) - obj.Box.Vertices(1,2));
            corner_dist = sqrt(dx.^2 + dy.^2);
            
            on_corner = (corner_dist <= buffer);
            in_box = cp(1,1)>=obj.Box.Vertices(1,1) && cp(1,1)<=obj.Box.Vertices(3,1) && ...
                     cp(1,2)>=obj.Box.Vertices(1,2) && cp(1,2)<=obj.Box.Vertices(3,2);
                 
            obj.ZoomBoxCollision = 0;
            
            if any(on_corner)
                obj.ZoomBoxCollision = 1;
                obj.DragIndices = find(corner_dist == min(corner_dist));
            elseif in_box
                obj.ZoomBoxCollision = 2;
                obj.DragIndices = [1,2,3,4,5];
            end
            
            if any(on_corner) || in_box
                obj.StartingBoxVertices = obj.Box.Vertices;
                obj.StartingPos = cp(1,1:2);
            end
                        
        end

        function startDrag(obj)
                        
           % save original figure units
           obj.ParentFigureOriginalUnits = obj.ParentFigure.Units;

           % now force to pixels for collision checking and motion
           obj.ParentFigure.Units = 'pixels';

           obj.check_zoom_axes_collision(10)
           
           if obj.ZoomAxesCollision>0
               obj.ParentFigure.WindowButtonMotionFcn = @(src,evdat)obj.drag_zoom_axes();
           else               
               obj.check_zoom_box_collision(0.1)
               if obj.ZoomBoxCollision>0
                obj.ParentFigure.WindowButtonMotionFcn = @(src,evdat)obj.drag_zoom_box();
               end
           end

           obj.ParentFigure.Units = obj.ParentFigureOriginalUnits;
            
        end
        
        function drag_zoom_box(obj)
            
            cp = obj.ParentAxes.CurrentPoint;
            
            dx = cp(1,1) - obj.StartingPos(1);
            dy = cp(1,2) - obj.StartingPos(2);
                      
            if obj.ZoomBoxCollision == 2 % moving
                
                obj.Box.Vertices = obj.StartingBoxVertices + [dx,dy];

            elseif obj.ZoomBoxCollision == 1 % resizing
                
                % Get candidate position and check add buffer region to
                % prevent box from inverting
                x_orig = obj.StartingBoxVertices(3,1) - obj.StartingBoxVertices(1,1);
                y_orig = obj.StartingBoxVertices(3,2) - obj.StartingBoxVertices(1,2);
                
                % set minimum acceptable zoom region length ratios
                xl_limit = 0.05;
                yl_limit = 0.05;
                
                if obj.DragIndices(1) == 1 || obj.DragIndices(1) == 5
                    dx_limit = (1.0-xl_limit)*x_orig;
                    dy_limit = (1.0-yl_limit)*y_orig;
                    dx = min(dx,dx_limit);
                    dy = min(dy,dy_limit);
                    obj.Box.Vertices(obj.DragIndices,:) = obj.StartingBoxVertices(obj.DragIndices,:) + [dx,dy];
                    obj.Box.Vertices(2,2) = obj.StartingBoxVertices(2,2) + dy;
                    obj.Box.Vertices(4,1) = obj.StartingBoxVertices(4,1) + dx;
                elseif obj.DragIndices(1) == 2
                    dx_limit = -(1.0-xl_limit)*x_orig;
                    dy_limit = (1.0-yl_limit)*y_orig;
                    dx = max(dx,dx_limit);
                    dy = min(dy,dy_limit);
                    obj.Box.Vertices(obj.DragIndices,:) = obj.StartingBoxVertices(obj.DragIndices,:) + [dx,dy];
                    obj.Box.Vertices([1,5],2) = obj.StartingBoxVertices([1,5],2) + dy;
                    obj.Box.Vertices(3,1) = obj.StartingBoxVertices(3,1) + dx;
                elseif obj.DragIndices(1) == 3
                    dx_limit = -(1.0-xl_limit)*x_orig;
                    dy_limit = -(1.0-yl_limit)*y_orig;
                    dx = max(dx,dx_limit);
                    dy = max(dy,dy_limit);
                    obj.Box.Vertices(obj.DragIndices,:) = obj.StartingBoxVertices(obj.DragIndices,:) + [dx,dy];
                    obj.Box.Vertices(4,2) = obj.StartingBoxVertices(4,2) + dy;
                    obj.Box.Vertices(2,1) = obj.StartingBoxVertices(3,1) + dx;
                elseif obj.DragIndices(1) == 4
                    dx_limit = (1.0-xl_limit)*x_orig;
                    dy_limit = -(1.0-yl_limit)*y_orig;
                    dx = min(dx,dx_limit);
                    dy = max(dy,dy_limit);
                    obj.Box.Vertices(obj.DragIndices,:) = obj.StartingBoxVertices(obj.DragIndices,:) + [dx,dy];
                    obj.Box.Vertices([1,5],1) = obj.StartingBoxVertices([1,5],1) + dx;
                    obj.Box.Vertices(3,2) = obj.StartingBoxVertices(3,2) + dy;
                end
                
            end
            
            
            % Have to pause zoom box update since updating the zoomed axes
            % limits will trigger the listener, which will re-adjust the
            % box, causing a race condition.
            obj.PauseBoxUpdate = true;
            
            % Update zoom axes limits and update box connectors for new box
            % location
            obj.update_axes_from_box();
            obj.update_box_connectors();
            obj.update_zoom_region_from_box();
            
            % Disable pausing of listener
            obj.PauseBoxUpdate = false;
            
        end
        
        function drag_zoom_axes(obj)
            
            % save original figure units
            obj.ParentFigureOriginalUnits = obj.ParentFigure.Units;

            % now force to pixels for motion
            obj.ParentFigure.Units = 'pixels';

            cp = obj.ParentFigure.CurrentPoint;
            dx = cp(1)-obj.StartingPos(1);
            dy = cp(2)-obj.StartingPos(2);
            
            % normalized units
            figPos = obj.ParentFigure.Position;
            dxNorm = dx/figPos(3);
            dyNorm = dy/figPos(4);

            dlims = 0.05;
            
            if obj.ZoomAxesCollision == 2 % moving
                obj.Axes.Position(1) = obj.StartingAxesPos(1) + dxNorm;
                obj.Axes.Position(2) = obj.StartingAxesPos(2) + dyNorm;
            elseif obj.ZoomAxesCollision == 1 % resizing

                dx_limit = obj.StartingAxesPos(3)*(1-dlims);
                dy_limit = obj.StartingAxesPos(4)*(1-dlims);

                if obj.DragIndices(1) == 1
                    dx = min(dxNorm, dx_limit);
                    dy = min(dyNorm, dy_limit);
                    obj.Axes.Position(1) = obj.StartingAxesPos(1) + dx;
                    obj.Axes.Position(2) = obj.StartingAxesPos(2) + dy;
                    obj.Axes.Position(3) = obj.StartingAxesPos(3)-dx;
                    obj.Axes.Position(4) = obj.StartingAxesPos(4)-dy;
                elseif obj.DragIndices == 2
                    dx = max(dxNorm, -dx_limit);
                    dy = min(dyNorm, dy_limit);
                    obj.Axes.Position(2) = obj.StartingAxesPos(2) + dy;
                    obj.Axes.Position(3) = obj.StartingAxesPos(3) + dx;
                    obj.Axes.Position(4) = obj.StartingAxesPos(4) - dy;
                elseif obj.DragIndices == 3
                    dx = max(dxNorm, -dx_limit);
                    dy = max(dyNorm, -dy_limit);
                    obj.Axes.Position(3) = obj.StartingAxesPos(3)+dx;
                    obj.Axes.Position(4) = obj.StartingAxesPos(4)+dy;
                elseif obj.DragIndices == 4
                    dx = min(dxNorm, dx_limit);
                    dy = max(dyNorm, -dy_limit);
                    obj.Axes.Position(1) = obj.StartingAxesPos(1) + dx;
                    obj.Axes.Position(3) = obj.StartingAxesPos(3) - dx;
                    obj.Axes.Position(4) = obj.StartingAxesPos(4) + dy;
                end
   
            end
            
            obj.update_box_connectors();

            obj.ParentFigure.Units = obj.ParentFigureOriginalUnits;
            
        end
        
        function stopDrag(obj)
            obj.ParentFigure.WindowButtonMotionFcn = @(src,evt) [];
            obj.ZoomAxesCollision = 0;
            obj.ZoomBoxCollision  = 0;
        end

        function coords = get_zoom_axes_coordinates(obj)
            
            % Returns the parent axes data limits corresponding
            % to the corners of the zoomed axes.
            %
            % Inputs:
            %   zoomAx   - handle to the zoomed axes (inset)
            %   parentAx - handle to the parent axes
            %
            % Outputs:
            %   xLim - [xmin xmax] in parent data coordinates
            %   yLim - [ymin ymax] in parent data coordinates
            
            % 1. Get normalized position of zoom axes relative to figure
            zoomPosNorm = obj.Axes.InnerPosition;      % [x y w h], normalized
            parentPosNorm = obj.ParentAxes.InnerPosition;  % [x y w h], normalized
            
            % 2. Calculate relative fraction inside parent axes
            xFrac = (zoomPosNorm(1) + [0 zoomPosNorm(3)]) - parentPosNorm(1);
            xFrac = xFrac / parentPosNorm(3);
            
            yFrac = (zoomPosNorm(2) + [0 zoomPosNorm(4)]) - parentPosNorm(2);
            yFrac = yFrac / parentPosNorm(4);
            
            % 3. Map fraction to parent axes data limits
            parentXLim = obj.ParentAxes.XLim;
            parentYLim = obj.ParentAxes.YLim;
            
            xMin = parentXLim(1) + xFrac(1)*(parentXLim(2)-parentXLim(1));
            xMax = parentXLim(1) + xFrac(2)*(parentXLim(2)-parentXLim(1));
            
            yMin = parentYLim(1) + yFrac(1)*(parentYLim(2)-parentYLim(1));
            yMax = parentYLim(1) + yFrac(2)*(parentYLim(2)-parentYLim(1));
            
            coords = [xMin; yMin; xMax; yMax];

        end
        
        function set_box_connector_visibility(obj)
            
            % get zoom axes coordinates
            coords = obj.get_zoom_axes_coordinates();
            
            % check bottom left connector
            if (coords(1) > obj.Box.XData(1) && coords(2) < obj.Box.YData(1)) || ...
               (coords(1) < obj.Box.XData(1) && coords(2) > obj.Box.YData(1))
                obj.BoxConnectors(1).Visible = 'on';
            else
                obj.BoxConnectors(1).Visible = 'off';
            end
            
             % check bottom right connector
            if (coords(3) < obj.Box.XData(2) && coords(2) < obj.Box.YData(2)) || ...
               (coords(3) > obj.Box.XData(2) && coords(2) > obj.Box.YData(2))
                obj.BoxConnectors(2).Visible = 'on';
            else
                obj.BoxConnectors(2).Visible = 'off';
            end
            
            % check top right connector
            if (coords(3) > obj.Box.XData(3) && coords(4) < obj.Box.YData(3)) || ...
               (coords(3) < obj.Box.XData(3) && coords(4) > obj.Box.YData(3))
                obj.BoxConnectors(3).Visible = 'on';
            else
                obj.BoxConnectors(3).Visible = 'off';
            end
            
            % check top left connector
            if (coords(1) < obj.Box.XData(4) && coords(4) < obj.Box.YData(4)) || ...
               (coords(1) > obj.Box.XData(4) && coords(4) > obj.Box.YData(4))
                obj.BoxConnectors(4).Visible = 'on';
            else
                obj.BoxConnectors(4).Visible = 'off';
            end
            
        end
        
        % Set connector visibility based on relative box / zoom axes position    
           
        function update_box_connectors(obj)
            
            % get coordinates of zoom axes bounds on the parent axis
            coords = obj.get_zoom_axes_coordinates();
            
            % start bottom left, go CCW
            xinds = [1 3 3 1];
            yinds = [2 2 4 4];
            for i = 1:4
                obj.BoxConnectors(i).XData = [obj.Box.XData(i); coords(xinds(i))];
                obj.BoxConnectors(i).YData = [obj.Box.YData(i); coords(yinds(i))];
            end
            
            obj.set_box_connector_visibility();
            
        end
        
        function update_zoom_region_from_box(obj)
        % Updates the ZoomRegion field to match the box

            obj.ZoomRegion = obj.Box.Vertices([1,6,3,8]);

        end

        function update_box_from_zoom_region(obj)
        % Updates the zoom box patch to match the coordinates in ZoomRegion

            % put inside pause check to avoid feedback between this and the inverse 
            % function when a listener is triggered
            if ~obj.PauseBoxUpdate
                obj.Box.Vertices = obj.ZoomRegion([1 2; 3 2; 3 4; 1 4; 1 2]);
                obj.update_box_connectors()
                obj.PauseBoxUpdate = true;
                obj.update_axes_from_box();
                obj.PauseBoxUpdate = false;
            end

        end

        function update_box_from_axes(obj)
            
            if ~obj.PauseBoxUpdate
                obj.Box.Vertices(:,1) = obj.Axes.XLim([1,2,2,1,1]);
                obj.Box.Vertices(:,2) = obj.Axes.YLim([1,1,2,2,1]);
                obj.update_box_connectors();
            end
            
        end

        function update_box_from_axes_2(obj)
            
            if ~obj.PauseBoxUpdate
                obj.Box.Vertices(:,1) = obj.Axes.XLim([1,2,2,1,1]);
                obj.Box.Vertices(:,2) = obj.Axes.YLim([1,1,2,2,1]);
                obj.update_box_connectors();
            end
            
        end
        
        function update_axes_from_box(obj)
            
            obj.Axes.XLim = obj.Box.Vertices([1,3],1);
            obj.Axes.YLim = obj.Box.Vertices([1,3],2);
            
        end
        
        function refresh_data(obj)
            
            delete(obj.Axes.Children);
            copyobj(obj.ParentAxes.Children, obj.Axes);
            
            % Check for things we don't want copied
            delInd = [];
            for i = 1:length(obj.Axes.Children)
                if strcmpi(obj.Axes.Children(i).Tag, 'zoombox')
                    delInd(end+1) = i;
                elseif strcmpi(obj.Axes.Children(i).Tag, 'zoomboxconnector')
                    delInd(end+1) = i;
                end
            end
            
            % Delete unwanted objects
            delete(obj.Axes.Children(delInd));                  
            
        end
        
        function print_zoom_region(obj, format)

            arguments
                obj zoomed_axes
                format char = "%.3e"
            end

            fprintf('[');
            fprintf(sprintf('%s, ', format), obj.ZoomRegion(1:3));
            fprintf(sprintf('%s', format), obj.ZoomRegion(4));
            fprintf(']\n');

        end

        function print_axes_position(obj, format)

            arguments
                obj zoomed_axes
                format char = "%.3f"
            end

            fprintf('[');
            fprintf(sprintf('%s, ', format), obj.Axes.Position(1:3));
            fprintf(sprintf('%s', format), obj.Axes.Position(4));
            fprintf(']\n');

        end

        function delete(obj)
        % DELETE Clean up when object is destroyed

            try
                % Delete child graphics (axes, patches, lines, etc.)
                if isvalid(obj.Axes)
                    delete(obj.Axes);
                end
                if ~isempty(obj.Box)
                    delete(obj.Box(ishandle(obj.Box)));
                end
                if ~isempty(obj.BoxConnectors)
                    delete(obj.BoxConnectors(ishandle(obj.BoxConnectors)));
                end

                % Remove self from global registry
                fig = obj.ParentFigure;
                if ~isempty(fig) && isvalid(fig)
                    list = getappdata(fig, 'ZoomedAxesList');
                    if ~isempty(list)
                        list = list(isvalid(list)); % remove dead refs
                        list(list == obj) = [];     % remove this object
                        setappdata(fig, 'ZoomedAxesList', list);
                    end
                end

                % Remove listeners (if you stored them in a property)
                if ~isempty(obj.Listeners)
                    delete(obj.Listeners(isvalid(obj.Listeners)));
                end

            catch ME
                warning('ZoomedAxes:deleteFailed', ...
                    'Error during deletion: %s', ME.message);
            end

        end

        function ax = unwrap(obj)
        % when called, just returns the axis handle
            ax = obj.Axes;
        end
        
    end

    % Assign global function that loops through the zoomed axes in the
    % current figure and runs their own functions
    methods (Static)
        
        function globalButtonDownFcn(fig,~)
            list = getappdata(fig, 'ZoomedAxesList');
            list = list(isvalid(list));  % drop invalid handles 
            setappdata(fig, 'ZoomedAxesList', list);
            for k = 1:numel(list)
                if isvalid(list(k))
                    list(k).startDrag();
                end
            end
        end
        
        function globalButtonUpFcn(fig,~)
            list = getappdata(fig, 'ZoomedAxesList');
            for k = 1:numel(list)
                if isvalid(list(k))
                    list(k).stopDrag();
                end
            end
        end

    end
   
    % methods used to forward axes behaviors
    % (taken from chatgpt)
    methods
        function varargout = subsref(obj,S)
            switch S(1).type
                case '.'
                    % If the property/method exists in wrapper, use it
                    if isprop(obj, S(1).subs) || ismethod(obj, S(1).subs)
                        [varargout{1:nargout}] = builtin('subsref', obj, S);
                    else
                        % Otherwise, forward to zoomed axes
                        [varargout{1:nargout}] = builtin('subsref', obj.Ax, S);
                    end
                otherwise
                    [varargout{1:nargout}] = builtin('subsref', obj, S);
            end
        end
        
        function obj = subsasgn(obj,S,val)
            switch S(1).type
                case '.'
                    % If property exists in wrapper, assign here
                    if isprop(obj, S(1).subs) || ismethod(obj, S(1).subs)
                        obj = builtin('subsasgn', obj, S, val);
                    else
                        % Otherwise, forward assignment to ZoomAx
                        obj.Axes = builtin('subsasgn', obj.Axes, S, val);
                    end
                otherwise
                    obj = builtin('subsasgn', obj, S, val);
            end
        end
    end 
    
    % Function overloads for labeling
    methods
        
    function title(obj, varargin)
        title(obj.Axes, varargin{:});
    end
    function xlabel(obj, varargin)
        xlabel(obj.Axes, varargin{:});
    end
    function ylabel(obj, varargin)
        ylabel(obj.Axes, varargin{:});
    end
    function xlim(obj, varargin)
        if nargin == 1
            xlim(obj.Axes) % get current limits
        else
            xlim(obj.Axes, varargin{:}); % set limits
        end
    end
    function ylim(obj, varargin)
        if nargin == 1
            ylim(obj.Axes)
        else
            ylim(obj.Axes, varargin{:})
        end
    end
    function plot(obj, varargin)
        plot(obj.Axes, varargin{:});
    end
    
    end
    
end
