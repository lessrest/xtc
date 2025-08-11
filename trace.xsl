<?xml version="1.0" encoding="UTF-8"?>
<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
    <xsl:output method="text" indent="no"/>
    <xsl:strip-space elements="*"/>
    
    <!-- Simple trace formatter - just clean structure with minimal processing -->
    
    <xsl:template match="/">
        <xsl:apply-templates select="span"/>
    </xsl:template>
    
    <xsl:template match="span">
        <xsl:param name="depth" select="0"/>
        
        <!-- Simple indentation -->
        <xsl:call-template name="indent">
            <xsl:with-param name="depth" select="$depth"/>
        </xsl:call-template>
        
        <!-- Span header -->
        <xsl:text>▶ </xsl:text>
        <xsl:value-of select="info[1]"/>
        <xsl:text>&#10;</xsl:text>
        
        <!-- Decisions -->
        <xsl:for-each select="decision">
            <xsl:call-template name="indent">
                <xsl:with-param name="depth" select="$depth + 1"/>
            </xsl:call-template>
            <xsl:text>⚡ </xsl:text>
            <xsl:value-of select="."/>
            <xsl:text>&#10;</xsl:text>
        </xsl:for-each>
        
        <!-- Data groups -->
        <xsl:for-each select="data">
            <xsl:apply-templates select="." mode="elements">
                <xsl:with-param name="depth" select="$depth + 1"/>
            </xsl:apply-templates>
        </xsl:for-each>
        
        <!-- Standalone items (outside data groups) -->
        <xsl:apply-templates select="item[not(parent::data)]">
            <xsl:with-param name="depth" select="$depth + 1"/>
        </xsl:apply-templates>
        
        <!-- Child spans -->
        <xsl:apply-templates select="span">
            <xsl:with-param name="depth" select="$depth + 1"/>
        </xsl:apply-templates>
    </xsl:template>
    
    <xsl:template match="item">
        <xsl:param name="depth" select="0"/>
        <xsl:call-template name="indent">
            <xsl:with-param name="depth" select="$depth"/>
        </xsl:call-template>
        <xsl:text>• </xsl:text>
        <xsl:value-of select="@key"/>
        <xsl:text>:</xsl:text>
        <xsl:choose>
            <xsl:when test="*">
                <!-- Has child elements - put on new line and process in element mode -->
                <xsl:text>&#10;</xsl:text>
                <xsl:apply-templates mode="elements">
                    <xsl:with-param name="depth" select="$depth + 1"/>
                </xsl:apply-templates>
            </xsl:when>
            <xsl:otherwise>
                <!-- Simple text content - inline in text mode -->
                <xsl:text> </xsl:text>
                <xsl:apply-templates mode="text"/>
                <xsl:text>&#10;</xsl:text>
            </xsl:otherwise>
        </xsl:choose>
    </xsl:template>
    
    <!-- Text mode: normalize whitespace -->
    <xsl:template match="text()" mode="text">
        <xsl:value-of select="normalize-space(.)"/>
    </xsl:template>
    
    <!-- Elements mode: process child elements with depth -->
    <xsl:template match="span" mode="elements">
        <xsl:param name="depth" select="0"/>
        <xsl:apply-templates select=".">
            <xsl:with-param name="depth" select="$depth"/>
        </xsl:apply-templates>
    </xsl:template>
    
    <xsl:template match="data" mode="elements">
        <xsl:param name="depth" select="0"/>
        <xsl:call-template name="indent">
            <xsl:with-param name="depth" select="$depth"/>
        </xsl:call-template>
        
        <xsl:text>🔸 </xsl:text>
        <xsl:value-of select="@label"/>
        
        <!-- Check if we can fit everything on one line -->
        <xsl:choose>
            <xsl:when test="not(item[*])">
                <!-- All simple items - use compact function-like format -->
                <xsl:text>(</xsl:text>
                <xsl:for-each select="item">
                    <xsl:if test="position() > 1">
                        <xsl:text>, </xsl:text>
                    </xsl:if>
                    <xsl:value-of select="@key"/>
                    <xsl:text>: </xsl:text>
                    <xsl:apply-templates mode="text"/>
                </xsl:for-each>
                <xsl:text>)&#10;</xsl:text>
            </xsl:when>
            <xsl:otherwise>
                <!-- Mixed complex/simple - use simpler approach -->
                <xsl:text>:&#10;</xsl:text>
                <xsl:call-template name="process-mixed-items">
                    <xsl:with-param name="depth" select="$depth + 1"/>
                </xsl:call-template>
            </xsl:otherwise>
        </xsl:choose>
    </xsl:template>
    
    <!-- Simple approach: scan through items and group simple ones -->
    <xsl:template name="process-mixed-items">
        <xsl:param name="depth"/>
        
        <xsl:variable name="items" select="item"/>
        <xsl:variable name="item-count" select="count($items)"/>
        
        <xsl:call-template name="scan-items">
            <xsl:with-param name="items" select="$items"/>
            <xsl:with-param name="depth" select="$depth"/>
            <xsl:with-param name="pos" select="1"/>
            <xsl:with-param name="item-count" select="$item-count"/>
        </xsl:call-template>
    </xsl:template>
    
    <xsl:template name="scan-items">
        <xsl:param name="items"/>
        <xsl:param name="depth"/>
        <xsl:param name="pos"/>
        <xsl:param name="item-count"/>
        
        <xsl:if test="$pos &lt;= $item-count">
            <xsl:variable name="current-item" select="$items[$pos]"/>
            
            <xsl:choose>
                <xsl:when test="not($current-item[*])">
                    <!-- Simple item - collect consecutive simple items -->
                    <xsl:call-template name="indent">
                        <xsl:with-param name="depth" select="$depth"/>
                    </xsl:call-template>
                    <xsl:text>• </xsl:text>
                    
                    <xsl:call-template name="output-consecutive-simple">
                        <xsl:with-param name="items" select="$items"/>
                        <xsl:with-param name="start-pos" select="$pos"/>
                        <xsl:with-param name="item-count" select="$item-count"/>
                    </xsl:call-template>
                    <xsl:text>&#10;</xsl:text>
                    
                    <!-- Skip past all simple items we just processed -->
                    <xsl:variable name="next-pos">
                        <xsl:call-template name="find-first-complex-after">
                            <xsl:with-param name="items" select="$items"/>
                            <xsl:with-param name="start-pos" select="$pos"/>
                            <xsl:with-param name="item-count" select="$item-count"/>
                        </xsl:call-template>
                    </xsl:variable>
                    
                    <!-- Continue scanning from the next complex item -->
                    <xsl:call-template name="scan-items">
                        <xsl:with-param name="items" select="$items"/>
                        <xsl:with-param name="depth" select="$depth"/>
                        <xsl:with-param name="pos" select="$next-pos"/>
                        <xsl:with-param name="item-count" select="$item-count"/>
                    </xsl:call-template>
                </xsl:when>
                <xsl:otherwise>
                    <!-- Complex item - output individually -->
                    <xsl:call-template name="indent">
                        <xsl:with-param name="depth" select="$depth"/>
                    </xsl:call-template>
                    <xsl:text>• </xsl:text>
                    <xsl:value-of select="$current-item/@key"/>
                    <xsl:text>:&#10;</xsl:text>
                    
                    <!-- Process nested content -->
                    <xsl:for-each select="$current-item/*">
                        <xsl:apply-templates select="." mode="elements">
                            <xsl:with-param name="depth" select="$depth + 1"/>
                        </xsl:apply-templates>
                    </xsl:for-each>
                    
                    <!-- Continue with next item -->
                    <xsl:call-template name="scan-items">
                        <xsl:with-param name="items" select="$items"/>
                        <xsl:with-param name="depth" select="$depth"/>
                        <xsl:with-param name="pos" select="$pos + 1"/>
                        <xsl:with-param name="item-count" select="$item-count"/>
                    </xsl:call-template>
                </xsl:otherwise>
            </xsl:choose>
        </xsl:if>
    </xsl:template>
    
    <xsl:template name="output-consecutive-simple">
        <xsl:param name="items"/>
        <xsl:param name="start-pos"/>
        <xsl:param name="item-count"/>
        <xsl:param name="current-pos" select="$start-pos"/>
        <xsl:param name="is-first" select="true()"/>
        
        <xsl:if test="$current-pos &lt;= $item-count">
            <xsl:variable name="current-item" select="$items[$current-pos]"/>
            
            <xsl:if test="not($current-item[*])">
                <xsl:if test="not($is-first)">
                    <xsl:text>, </xsl:text>
                </xsl:if>
                
                <xsl:value-of select="$current-item/@key"/>
                <xsl:text>: </xsl:text>
                <xsl:for-each select="$current-item">
                    <xsl:apply-templates mode="text"/>
                </xsl:for-each>
                
                <!-- Continue with next item -->
                <xsl:call-template name="output-consecutive-simple">
                    <xsl:with-param name="items" select="$items"/>
                    <xsl:with-param name="start-pos" select="$start-pos"/>
                    <xsl:with-param name="item-count" select="$item-count"/>
                    <xsl:with-param name="current-pos" select="$current-pos + 1"/>
                    <xsl:with-param name="is-first" select="false()"/>
                </xsl:call-template>
            </xsl:if>
        </xsl:if>
    </xsl:template>
    
    <xsl:template name="find-first-complex-after">
        <xsl:param name="items"/>
        <xsl:param name="start-pos"/>
        <xsl:param name="item-count"/>
        <xsl:param name="current-pos" select="$start-pos"/>
        
        <xsl:choose>
            <xsl:when test="$current-pos > $item-count">
                <xsl:value-of select="$current-pos"/>
            </xsl:when>
            <xsl:when test="$items[$current-pos][*]">
                <xsl:value-of select="$current-pos"/>
            </xsl:when>
            <xsl:otherwise>
                <xsl:call-template name="find-first-complex-after">
                    <xsl:with-param name="items" select="$items"/>
                    <xsl:with-param name="start-pos" select="$start-pos"/>
                    <xsl:with-param name="item-count" select="$item-count"/>
                    <xsl:with-param name="current-pos" select="$current-pos + 1"/>
                </xsl:call-template>
            </xsl:otherwise>
        </xsl:choose>
    </xsl:template>
    
    <!-- Simple indent helper -->
    <xsl:template name="indent">
        <xsl:param name="depth"/>
        <xsl:if test="$depth > 0">
            <xsl:text>  </xsl:text>
            <xsl:call-template name="indent">
                <xsl:with-param name="depth" select="$depth - 1"/>
            </xsl:call-template>
        </xsl:if>
    </xsl:template>
    
</xsl:stylesheet>